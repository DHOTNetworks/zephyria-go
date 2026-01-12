package p2p

import (
	"math/big"
	"testing"

	"zephyria/types"

	ethtypes "github.com/ethereum/go-ethereum/core/types"
)

func TestRotor_EndToEnd(t *testing.T) {
	rotor, err := NewRotor()
	if err != nil {
		t.Fatalf("Failed to create rotor: %v", err)
	}

	// Create Dummy Block
	header := &types.Header{
		Number:    big.NewInt(100),
		ExtraData: make([]byte, 32),
	}
	block := types.NewBlock(header, []*ethtypes.Transaction{})

	// 1. Shred
	shreds, err := rotor.ShredBlock(block, nil)
	if err != nil {
		t.Fatalf("ShredBlock failed: %v", err)
	}

	if len(shreds) != 30 {
		t.Errorf("Expected 30 shards, got %d", len(shreds))
	}

	// 2. Drop Packets (Simulate 50% loss, need 10/30)
	// We keep 10 random
	shredMap := make(map[uint64][]byte)
	for i := 0; i < 10; i++ {
		shredMap[shreds[i].Index] = shreds[i].Data
	}

	// 3. Reconstruct
	recBlock, err := rotor.Reconstruct(shredMap, 0)
	if err != nil {
		t.Fatalf("Reconstruct failed: %v", err)
	}

	if recBlock.Hash() != block.Hash() {
		t.Errorf("Hash Mismatch. Original: %s, Reconstructed: %s", block.Hash().Hex(), recBlock.Hash().Hex())
	}
}
