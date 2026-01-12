package consensus

import (
	"fmt"
	"math/big"
	"testing"
	"time"

	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

func TestZelius_Performance_TPS(t *testing.T) {
	// 1. Setup Consensus Engine with Multiple Validators
	validatorCount := 4
	var validators []*Validator
	var keys []*big.Int

	for i := 0; i < validatorCount; i++ {
		k, _ := crypto.GenerateKey()
		addr := crypto.PubkeyToAddress(k.PublicKey)
		validators = append(validators, &Validator{
			Address: addr,
			Stake:   big.NewInt(1000),
		})
		keys = append(keys, new(big.Int).SetBytes(crypto.FromECDSA(k)))
	}

	// Local node is Validator 0
	localKey, _ := crypto.ToECDSA(keys[0].Bytes())
	engine := NewZelius(validators, localKey, nil)

	// Tune VDF for measurable delay (Simulating ~100ms block time or similar)
	// SHA256 is very fast. 100k iterations might be measurable.
	engine.VDFIterations = 100000

	// 2. Generate Dummy Transactions
	txCount := 5000 // Total pool
	var txs []*ethtypes.Transaction

	// Create a dummy signer
	signer := ethtypes.NewEIP155Signer(big.NewInt(1))

	fmt.Println("Generating transactions...")
	for i := 0; i < txCount; i++ {
		// Minimal tx
		tx := ethtypes.NewTransaction(uint64(i), common.Address{}, big.NewInt(100), 21000, big.NewInt(1), nil)
		// Signs are expensive, for pure consensus engine bench we might skip verifying sigs
		// but SimulateRound just passes them through types.NewBlock.
		// So we don't strictly need valid signatures for this micro-benchmark of the ENGINE logic.
		// ethtypes.Transaction is enough.
		signedTx, _ := ethtypes.SignTx(tx, signer, localKey)
		txs = append(txs, signedTx)
	}

	// 3. Run Simulation Loop
	blockCount := 50

	genesisHeader := &types.Header{
		Number:    big.NewInt(0),
		Time:      uint64(time.Now().Unix()),
		ExtraData: make([]byte, 32),
	}
	parent := types.NewBlock(genesisHeader, nil)

	startTime := time.Now()

	totalTxsIncluded := 0

	fmt.Printf("Starting Simulation: %d Blocks, %d Validators\n", blockCount, validatorCount)

	for i := 0; i < blockCount; i++ {
		// Pick a new leader (Simulate turn taking or just use engine logic)
		// For SimulateRound, the engine checks if *it* is the leader?
		// No, SimulateRound just produces a block assuming IT IS the proposer.
		// Then we'd verify it.

		// We pack 1000 txs per block
		batchSize := 1000
		start := (i * batchSize) % txCount
		end := start + batchSize
		if end > txCount {
			end = txCount
		}
		batch := txs[start:end]

		bStart := time.Now()
		block, err := engine.SimulateRound(parent, batch, nil, nil)
		if err != nil {
			t.Fatalf("Block production failed: %v", err)
		}
		bDuration := time.Since(bStart)

		// Validate VDF existence
		if len(block.Header.ExtraData) < 32 {
			t.Fatalf("VDF missing")
		}

		totalTxsIncluded += len(batch)
		parent = block

		if i%10 == 0 {
			fmt.Printf("Block %d produced in %v (Txs: %d)\n", i+1, bDuration, len(batch))
		}
	}

	duration := time.Since(startTime)

	tps := float64(totalTxsIncluded) / duration.Seconds()
	avgBlockTime := duration.Seconds() / float64(blockCount)

	fmt.Println("========================================")
	fmt.Printf("Total Time: %v\n", duration)
	fmt.Printf("Total Blocks: %d\n", blockCount)
	fmt.Printf("Total Txs: %d\n", totalTxsIncluded)
	fmt.Printf("TPS: %.2f\n", tps)
	fmt.Printf("Avg Block Time: %.4f s\n", avgBlockTime)
	fmt.Println("========================================")

	if tps < 100 {
		t.Errorf("TPS too low: %.2f", tps)
	}
}
