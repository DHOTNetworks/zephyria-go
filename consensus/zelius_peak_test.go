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

func TestZelius_PeakPerformance_Saturated(t *testing.T) {
	// 1. Setup Consensus Engine with 4 Validators
	nodeCount := 4
	var validators []*Validator
	var keys []*big.Int

	for i := 0; i < nodeCount; i++ {
		k, _ := crypto.GenerateKey()
		addr := crypto.PubkeyToAddress(k.PublicKey)
		validators = append(validators, &Validator{
			Address: addr,
			Stake:   big.NewInt(100),
		})
		keys = append(keys, new(big.Int).SetBytes(crypto.FromECDSA(k)))
	}

	// Local node is Validator 0
	localKey, _ := crypto.ToECDSA(keys[0].Bytes())
	engine := NewZelius(validators, localKey, nil)

	// Realistic VDF iterations for consistent timing
	engine.VDFIterations = 50000
	engine.VDFCheckpointInterval = 10000

	// 2. Generate Saturated Transaction Pool
	// 60,000,000 Gas Limit / 21,000 Gas per Tx = 2,857 Txs
	txsPerBlock := 2857
	blockCount := 50
	totalNeeded := txsPerBlock * blockCount

	fmt.Printf("Generating %d signed transactions for saturation coverage...\n", totalNeeded)
	var txs []*ethtypes.Transaction
	signer := ethtypes.NewEIP155Signer(big.NewInt(1))

	for i := 0; i < totalNeeded; i++ {
		tx := ethtypes.NewTransaction(uint64(i), common.Address{}, big.NewInt(100), 21000, big.NewInt(1), nil)
		signedTx, _ := ethtypes.SignTx(tx, signer, localKey)
		txs = append(txs, signedTx)
	}

	// 3. Peak Load Simulation
	genesisHeader := &types.Header{
		Number:    big.NewInt(0),
		Time:      uint64(time.Now().Unix()),
		ExtraData: make([]byte, 160), // Match current ExtraData layout
	}
	latestBlock := types.NewBlock(genesisHeader, nil)

	startTime := time.Now()
	totalGasUsed := uint64(0)
	totalTxsIncluded := 0

	fmt.Printf("\n[🚀] Starting Peak Saturation Test (100%% Load | 60M Gas per Block)\n")
	fmt.Println("====================================================================")

	for i := 0; i < blockCount; i++ {
		startIdx := i * txsPerBlock
		batch := txs[startIdx : startIdx+txsPerBlock]

		bStart := time.Now()

		// SimulateRound produces the block and performs VDF work
		block, err := engine.SimulateRound(latestBlock, batch, nil, nil)
		if err != nil {
			t.Fatalf("Block production failed at #%d: %v", i+1, err)
		}

		bDuration := time.Since(bStart)

		// Update Stats
		gasInBlock := uint64(len(batch) * 21000)
		totalGasUsed += gasInBlock
		totalTxsIncluded += len(batch)
		latestBlock = block

		if (i+1)%10 == 0 || i == 0 {
			fmt.Printf("Block #%d: %d Txs | %d Gas | Time: %v | Total Txs: %d\n",
				i+1, len(batch), gasInBlock, bDuration, totalTxsIncluded)
		}
	}

	totalDuration := time.Since(startTime)
	tps := float64(totalTxsIncluded) / totalDuration.Seconds()
	avgBlockTime := totalDuration.Seconds() / float64(blockCount)
	gasPerSec := float64(totalGasUsed) / totalDuration.Seconds()

	fmt.Println("====================================================================")
	fmt.Printf("PEAK PERFORMANCE RESULTS\n")
	fmt.Printf("Total Duration:   %v\n", totalDuration)
	fmt.Printf("Total Blocks:     %d\n", blockCount)
	fmt.Printf("Total Txs:        %d\n", totalTxsIncluded)
	fmt.Printf("Total Gas Used:   %d\n", totalGasUsed)
	fmt.Printf("------------------------------------\n")
	fmt.Printf("TPS:              %.2f tx/s\n", tps)
	fmt.Printf("Avg Block Time:   %.4f s\n", avgBlockTime)
	fmt.Printf("Gas Throughput:   %.2f gas/s\n", gasPerSec)
	fmt.Println("====================================================================")

	// Quality Check
	if tps < 1000 {
		t.Errorf("Performance Regression: Expected > 1000 TPS under saturated load, got %.2f", tps)
	}
}
