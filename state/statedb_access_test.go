package state

import (
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/params"
)

func TestAccessList(t *testing.T) {
	// Berlin rules enable Access Lists
	rules := params.Rules{IsBerlin: true}

	s := New(common.Hash{}, nil) // nil DB for memory-only

	addr := common.HexToAddress("0x0000000000000000000000000000000000000001")
	slot := common.HexToHash("0x0000000000000000000000000000000000000000000000000000000000000001")

	// Initialize Access List
	// Note: Prepare is usually called by Executor with a tx's access list.
	// We call it here to init the internal map.
	s.Prepare(rules, common.Address{}, common.Address{}, nil, nil, nil)

	// verify initially cold
	if s.AddressInAccessList(addr) {
		t.Errorf("Address should be cold initially")
	}
	if ok, _ := s.SlotInAccessList(addr, slot); ok {
		t.Errorf("Address/Slot should be cold initially")
	}

	// Add address
	s.AddAddressToAccessList(addr)
	if !s.AddressInAccessList(addr) {
		t.Errorf("Address should be warm after addition")
	}

	// Add slot
	s.AddSlotToAccessList(addr, slot)
	addrOk, slotOk := s.SlotInAccessList(addr, slot)
	if !addrOk {
		t.Errorf("Address should be warm")
	}
	if !slotOk {
		t.Errorf("Slot should be warm after addition")
	}
}
