package core

import (
	"math/big"
	"testing"
	"zephyria/state"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
)

// BenchmarkAquarius_MassiveGame simulates a high-concurrency game.
// Scenario:
// - 1 "Game Logic" Smart Contract (Program Account)
// - N "Player" Data Accounts linked to the Game Logic.
// - N Transactions, one per player, executing a "Move".
//
// In Standard EVM: All N txs call the Game Contract. If the Game Contract modifies its own storage (or is just a bottleneck), they serialize (or conflict on access lists).
// In Aquarius: Txs target Player Accounts. They READ the Game Logic (Program) and WRITE to Player Account.
// Result: N transactions should be scheduled in 1 SINGLE WAVE (Parallel).
func BenchmarkAquarius_MassiveGame(b *testing.B) {
	// 1. Setup
	exec := &Executor{
		config: &params.ChainConfig{
			ChainID:     big.NewInt(1),
			BerlinBlock: big.NewInt(0),
		},
	}
	statedb := state.New(common.Hash{}, nil)

	// 2. Deploy Game Logic (Program)
	progAddr := common.BytesToAddress([]byte{0xAA, 0xBB, 0xCC})
	// Simple code: PUSH1 0x01 PUSH1 0x00 SSTORE (Set slot 0 to 1) - effectively "updating state"
	// In Aquarius, this executes on the DATA ACCOUNT context, purely reading Program code.
	progCode := []byte{0x60, 0x01, 0x60, 0x00, 0x55, 0x00}
	statedb.CreateAccount(progAddr)
	statedb.SetCode(progAddr, progCode, tracing.CodeChangeReason(0))

	// 3. Setup Players (Data Accounts)
	const PlayerCount = 1000
	players := make([]common.Address, PlayerCount)
	txs := make([]*types.Transaction, PlayerCount)

	for i := 0; i < PlayerCount; i++ {
		// Unique Player Address
		players[i] = common.BytesToAddress(crypto.Keccak256(big.NewInt(int64(i)).Bytes()))
		statedb.CreateAccount(players[i])
		// Link to Game Logic
		statedb.SetProgramAddress(players[i], progAddr)

		// Create Transaction targeting Player
		key, _ := crypto.GenerateKey()
		// No AccessList needed for basic functional test, but strictly:
		// Aquarius implies implicit read of ProgAddr.
		// Our Scheduler detects this via statedb.GetProgramAddress(To).
		txs[i] = createTx(b, 0, players[i], nil, key)
	}

	b.ResetTimer()
	b.ReportAllocs()

	for n := 0; n < b.N; n++ {
		// Run Scheduler
		// We are benchmarking the SCHEDULING capability primarily.
		waves := exec.schedule(txs, statedb)

		// Sanity Check (integrity)
		if len(waves) != 1 {
			b.Fatalf("Aquarius Integrity Failure! Expected 1 Wave (Parallel), got %d. Parallelism broken.", len(waves))
		}
	}
}

// BenchmarkStandard_MassiveContention simulates the "Old World".
// All players call the SAME contract address (The Game).
// Even if they touch different storage slots, the Scheduler (AccessList based) sees them all touching the SAME Recipient.
// Result: N transactions should be scheduled in N WAVES (Serialized), or at least heavily conflicted.
func BenchmarkStandard_MassiveContention(b *testing.B) {
	exec := &Executor{
		config: &params.ChainConfig{
			ChainID:     big.NewInt(1),
			BerlinBlock: big.NewInt(0),
		},
	}
	statedb := state.New(common.Hash{}, nil)

	// Game Contract
	gameAddr := common.BytesToAddress([]byte{0xAA, 0xBB, 0xCC})
	statedb.CreateAccount(gameAddr)

	const PlayerCount = 1000
	txs := make([]*types.Transaction, PlayerCount)

	for i := 0; i < PlayerCount; i++ {
		key, _ := crypto.GenerateKey()
		// All txs target SAME address (GameAddr)
		txs[i] = createTx(b, 0, gameAddr, nil, key)
	}

	b.ResetTimer()

	for n := 0; n < b.N; n++ {
		waves := exec.schedule(txs, statedb)

		// Expectation: Serialization
		// Since they all write to 'gameAddr' (Recipient), they conflict.
		// Should be more than 1 wave. Likely PlayerCount waves if naive.
		if len(waves) <= 1 {
			b.Fatalf("Standard Integrity Failure! Expected Fail/Serialization, got %d waves. Optimization logic leaking?", len(waves))
		}
	}
}
