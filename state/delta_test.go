package state

import (
	"math/big"
	"testing"

	// self-reference usually disallowed in same package test if 'package state_test'
	"github.com/ethereum/go-ethereum/common"
	// "github.com/ethereum/go-ethereum/crypto"
)

// Use package state logic directly (whitebox) to test Merge
// So package should be 'state'
// But wait, if I use 'package state', I don't import 'zephyria/state'.

func TestStateDB_DeltaMerge(t *testing.T) {
	// 1. Setup Base State
	s := New(common.Hash{}, nil)

	addr := common.BytesToAddress([]byte{0x01})
	key := common.Hash{0x01} // Key for storage

	// Set Initial Value: 100
	initialVal := big.NewInt(100)
	s.setVerkleValue(StorageKey(addr, key), common.LeftPadBytes(initialVal.Bytes(), 32))

	// 2. Parallel Overlays
	// Simulating parallel execution where they don't see each other's changes
	o1 := s.NewOverlay()
	o2 := s.NewOverlay()

	// 3. Transactions emit Deltas
	// T1: +50
	delta1 := big.NewInt(50)
	o1.AddStateDelta(StorageKey(addr, key), delta1)

	// T2: -30
	delta2 := big.NewInt(-30)
	o2.AddStateDelta(StorageKey(addr, key), delta2)

	// 4. Merge Phase (Sequential)
	// Apply T1
	o1.Merge()

	// Check Intermediate (Should be 150)
	valBytes := s.getVerkleValue(StorageKey(addr, key))
	val := new(big.Int).SetBytes(valBytes)
	if val.Cmp(big.NewInt(150)) != 0 {
		t.Errorf("After Merge 1: Expected 150, got %v", val)
	}

	// Apply T2
	o2.Merge()

	// Check Final (Should be 120)
	valBytes = s.getVerkleValue(StorageKey(addr, key))
	val = new(big.Int).SetBytes(valBytes)
	if val.Cmp(big.NewInt(120)) != 0 {
		t.Errorf("After Merge 2: Expected 120, got %v", val)
	}
}

func TestStateDB_DeltaAccumulation(t *testing.T) {
	s := New(common.Hash{}, nil)
	o1 := s.NewOverlay()

	key := []byte("test_accumulator")

	// Call +5, then +5
	o1.AddStateDelta(key, big.NewInt(5))
	o1.AddStateDelta(key, big.NewInt(5))

	// Verify internal map (whitebox)
	keyStr := string(key)
	if o1.deltas[keyStr].Cmp(big.NewInt(10)) != 0 {
		t.Errorf("Accumulation failed. Expected 10, got %v", o1.deltas[keyStr])
	}

	// Merge
	o1.Merge()

	// Verify Parent
	valBytes := s.getVerkleValue(key)
	val := new(big.Int).SetBytes(valBytes)
	if val.Cmp(big.NewInt(10)) != 0 {
		t.Errorf("Merge failed. Expected 10, got %v", val)
	}
}
