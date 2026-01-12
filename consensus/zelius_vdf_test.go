package consensus

import (
	"math/big"
	"testing"
	"time"

	"zephyria/types"

	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

func TestZelius_VDFIntegration(t *testing.T) {
	// Setup Engine
	k1, _ := crypto.GenerateKey()
	validators := []*Validator{
		{
			Address: crypto.PubkeyToAddress(k1.PublicKey),
			Stake:   big.NewInt(100),
			// No BLS key needed for VDF check, but engine needs it to simplify
		},
	}
	engine := NewZelius(validators, k1, nil)

	// Default iter = 50k, interval = 10k => 5 checkpoints => 160 bytes

	// Create Genesis Block (Empty ExtraData or 160 bytes zero)
	genesisHeader := &types.Header{
		Number:    big.NewInt(0),
		Time:      uint64(time.Now().Unix()),
		ExtraData: make([]byte, 160), // Genesis VDF = 0s
	}
	genesisBlock := types.NewBlock(genesisHeader, nil)

	// Simulate Block 1
	// Should compute VDF(Genesis.ExtraData[end-32:])
	block1, err := engine.SimulateRound(genesisBlock, []*ethtypes.Transaction{}, nil, nil)
	if err != nil {
		t.Fatalf("Failed to simulate round: %v", err)
	}

	// Verify Block 1 has VDF Checkpoints
	expectedSize := 160 // 5 * 32
	if len(block1.Header.ExtraData) < expectedSize {
		t.Fatalf("Block 1 missing VDF Checkpoints in ExtraData. Got %d, Want %d", len(block1.Header.ExtraData), expectedSize)
	}

	vdf1 := block1.Header.ExtraData[:expectedSize]
	lastCP := vdf1[expectedSize-32:]

	// Manually verify VDF
	// Genesis input was last 32 bytes of genesis ExtraData (all zeros)
	genInput := genesisHeader.ExtraData[160-32:]

	// Compute Checkpoints
	cps := engine.VDF.ComputeWithCheckpoints(genInput, engine.VDFIterations, engine.VDFCheckpointInterval)

	// Compare last checkpoint
	if string(lastCP) != string(cps[len(cps)-1]) {
		t.Errorf("Block 1 VDF mismatch")
	}

	// Simulate Block 2
	block2, err := engine.SimulateRound(block1, []*ethtypes.Transaction{}, nil, nil)
	if err != nil {
		t.Fatalf("Failed to simulate round 2: %v", err)
	}

	vdf2 := block2.Header.ExtraData[:expectedSize]
	lastCP2 := vdf2[expectedSize-32:]

	// Compute from Previous Last Checkpoint
	cps2 := engine.VDF.ComputeWithCheckpoints(lastCP, engine.VDFIterations, engine.VDFCheckpointInterval)

	if string(lastCP2) != string(cps2[len(cps2)-1]) {
		t.Errorf("Block 2 VDF mismatch (Chain broken)")
	}

	t.Log("VDF Chain Integration Verified Successfully")
}
