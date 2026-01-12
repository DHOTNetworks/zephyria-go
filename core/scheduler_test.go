package core

import (
	"crypto/ecdsa"
	"math/big"
	"testing"
	"zephyria/state"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
)

// Helper to create a signed transaction with access list
func createTx(tb testing.TB, nonce uint64, to common.Address, accessList types.AccessList, key *ecdsa.PrivateKey) *types.Transaction {
	chainID := big.NewInt(1)
	txData := &types.AccessListTx{
		ChainID:    chainID,
		Nonce:      nonce,
		GasPrice:   big.NewInt(1),
		Gas:        21000,
		To:         &to,
		Value:      big.NewInt(1),
		Data:       nil,
		AccessList: accessList,
	}
	tx, err := types.SignNewTx(key, types.NewEIP2930Signer(chainID), txData)
	if err != nil {
		if tb != nil {
			tb.Fatalf("Failed to sign tx: %v", err)
		} else {
			panic(err)
		}
	}
	return tx
}

func TestScheduler_AccessListParallelism(t *testing.T) {
	// Setup
	exec := &Executor{
		config: &params.ChainConfig{
			ChainID:     big.NewInt(1),
			BerlinBlock: big.NewInt(0), // Enable EIP-2930
			LondonBlock: big.NewInt(0), // Enable EIP-1559
		},
	}
	statedb := state.New(common.Hash{}, nil)

	addr1 := common.Address{1}
	addr2 := common.Address{2}
	addr3 := common.Address{3}
	addr4 := common.Address{4}

	// 1. Independent Transactions
	key1, _ := crypto.GenerateKey()
	key2, _ := crypto.GenerateKey()

	tx1 := createTx(t, 0, addr1, types.AccessList{{Address: addr2}}, key1)
	tx2 := createTx(t, 0, addr3, types.AccessList{{Address: addr4}}, key2)

	waves := exec.schedule([]*types.Transaction{tx1, tx2}, statedb)
	if len(waves) != 1 {
		t.Errorf("Expected 1 wave for independent txs, got %d", len(waves))
	}

	// 2. Conflicting via Access List
	key3, _ := crypto.GenerateKey()
	tx3 := createTx(t, 0, addr1, nil, key3)

	wavesConflict := exec.schedule([]*types.Transaction{tx1, tx3}, statedb)
	if len(wavesConflict) != 2 {
		t.Errorf("Expected 2 waves for conflicting recipients, got %d", len(wavesConflict))
	}

	// 3. Indirect Conflict via Access List
	key5, _ := crypto.GenerateKey()
	tx5 := createTx(t, 0, addr2, nil, key5)

	wavesIndirect := exec.schedule([]*types.Transaction{tx1, tx5}, statedb)
	if len(wavesIndirect) != 2 {
		t.Errorf("Expected 2 waves for AL vs Recipient conflict, got %d", len(wavesIndirect))
	}
}

func TestScheduler_AquariusParallelism(t *testing.T) {
	// Setup
	exec := &Executor{
		config: &params.ChainConfig{
			ChainID:     big.NewInt(1),
			BerlinBlock: big.NewInt(0),
		},
	}
	statedb := state.New(common.Hash{}, nil)

	// Setup Program
	progAddr := common.BytesToAddress([]byte{0xAA})
	progCode := []byte{0x60, 0x00}
	statedb.CreateAccount(progAddr)
	statedb.SetCode(progAddr, progCode, tracing.CodeChangeReason(0))

	// Setup Data Accounts linked to SAME Program
	data1 := common.BytesToAddress([]byte{0xDA, 0x01})
	statedb.CreateAccount(data1)
	statedb.SetProgramAddress(data1, progAddr)

	data2 := common.BytesToAddress([]byte{0xDA, 0x02})
	statedb.CreateAccount(data2)
	statedb.SetProgramAddress(data2, progAddr)

	// Tx1 -> Data1 (Reads Prog)
	// Tx2 -> Data2 (Reads Prog)
	key1, _ := crypto.GenerateKey()
	tx1 := createTx(t, 0, data1, nil, key1)

	key2, _ := crypto.GenerateKey()
	tx2 := createTx(t, 0, data2, nil, key2)

	// Expectation: Parallel (Same Wave) because Read-Read on Prog is allowed
	waves := exec.schedule([]*types.Transaction{tx1, tx2}, statedb)
	if len(waves) != 1 {
		t.Errorf("Aquarius Parallelism Failed. Expected 1 wave, got %d", len(waves))
	}
}

func TestScheduler_AquariusConflict(t *testing.T) {
	// Setup
	exec := &Executor{
		config: &params.ChainConfig{ChainID: big.NewInt(1)},
	}
	statedb := state.New(common.Hash{}, nil)

	// Setup Program
	progAddr := common.BytesToAddress([]byte{0xAA})
	// Setup Data Account linked to Program
	data1 := common.BytesToAddress([]byte{0xDA, 0x01})
	statedb.CreateAccount(data1)
	statedb.SetProgramAddress(data1, progAddr)

	// Tx1 -> Data1 (Implicitly READS Prog)
	key1, _ := crypto.GenerateKey()
	tx1 := createTx(t, 0, data1, nil, key1)

	// Tx2 -> Prog (Direct WRITE to Prog, e.g. Contract Update or just AccessList inclusion)
	// We force a Write by adding Prog to AccessList (Scheduler treats AccessList as WRITE)
	key2, _ := crypto.GenerateKey()
	// Recipient is random/irrelevant, AccessList contains Prog
	tx2 := createTx(t, 0, common.Address{0xEE}, types.AccessList{{Address: progAddr}}, key2)

	// Expectation: Conflict (Read vs Write on Prog). Two waves.
	waves := exec.schedule([]*types.Transaction{tx1, tx2}, statedb)
	if len(waves) != 2 {
		t.Errorf("Aquarius Conflict Failed. Expected 2 waves, got %d", len(waves))
	}
}

func BenchmarkScheduler_Disjoint(b *testing.B) {
	exec := &Executor{
		config: &params.ChainConfig{ChainID: big.NewInt(1)},
	}
	statedb := state.New(common.Hash{}, nil)
	txs := make([]*types.Transaction, 100)
	for i := 0; i < 100; i++ {
		addr := common.BytesToAddress(crypto.Keccak256([]byte{byte(i)}))
		k, _ := crypto.GenerateKey()
		txs[i] = createTx(b, uint64(i), addr, nil, k)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		exec.schedule(txs, statedb)
	}
}

func BenchmarkScheduler_Conflict(b *testing.B) {
	exec := &Executor{
		config: &params.ChainConfig{ChainID: big.NewInt(1)},
	}
	statedb := state.New(common.Hash{}, nil)
	txs := make([]*types.Transaction, 100)
	key, _ := crypto.GenerateKey()
	addr := common.Address{1}
	for i := 0; i < 100; i++ {
		txs[i] = createTx(b, uint64(i), addr, nil, key)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		exec.schedule(txs, statedb)
	}
}
