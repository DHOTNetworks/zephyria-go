package state

import (
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

func TestStateDB_Journal_AccessList(t *testing.T) {
	// Initialize
	db := New(common.Hash{}, nil)
	rules := params.Rules{IsBerlin: true}
	db.Prepare(rules, common.Address{}, common.Address{}, nil, nil, nil)

	addr := common.Address{0x01}

	// Snapshot 0
	snap := db.Snapshot()

	// Add to Access List
	db.AddAddressToAccessList(addr)
	if !db.AddressInAccessList(addr) {
		t.Fatalf("Address should be in access list")
	}

	// Revert
	db.RevertToSnapshot(snap)

	// Check removal
	if db.AddressInAccessList(addr) {
		t.Fatalf("Address should NOT be in access list after revert")
	}
}

func TestStateDB_Journal_Storage(t *testing.T) {
	db := New(common.Hash{}, nil)
	addr := common.Address{0x01}

	// Set initial balance
	db.SetBalance(addr, uint256.NewInt(100), tracing.BalanceChangeReason(0))

	snap := db.Snapshot()

	// Modify balance
	db.SetBalance(addr, uint256.NewInt(200), tracing.BalanceChangeReason(0))
	if db.GetBalance(addr).Uint64() != 200 {
		t.Fatalf("Balance didn't update")
	}

	// Revert
	db.RevertToSnapshot(snap)

	if db.GetBalance(addr).Uint64() != 100 {
		t.Errorf("Balance mismatch after revert. Got %v, want 100", db.GetBalance(addr))
	}
}
