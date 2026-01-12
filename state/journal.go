package state

import (
	"github.com/ethereum/go-ethereum/common"
)

// JournalEntry is a modification that can be reverted.
type JournalEntry interface {
	revert(*StateDB)
}

// accessListAddChange tracks the addition of an address to the access list
type accessListAddChange struct {
	address common.Address
}

func (ch accessListAddChange) revert(s *StateDB) {
	// We need to remove the address from the access list.
	// But accessList struct doesn't have Remove?
	// We need to implement generic remove or handle it.
	// EIP-2930 doesn't support removing, but Revert must undo the addition.
	if s.accessList != nil {
		delete(s.accessList.addresses, ch.address)
		delete(s.accessList.slots, ch.address) // Also remove slots if address is removed?
		// Actually, if we added address, we didn't add slots in THIS entry.
		// Slots are separate entries.
	}
}

// accessListAddSlotChange tracks the addition of a slot
type accessListAddSlotChange struct {
	address common.Address
	slot    common.Hash
}

func (ch accessListAddSlotChange) revert(s *StateDB) {
	if s.accessList != nil {
		if slots, ok := s.accessList.slots[ch.address]; ok {
			delete(slots, ch.slot)
		}
	}
}

// storageChange tracks a change in storage (dirty map)
type storageChange struct {
	key      string
	prevVal  []byte
	prevDirt bool // was it in dirty map before?
}

func (ch storageChange) revert(s *StateDB) {
	if ch.prevDirt {
		s.dirty[ch.key] = ch.prevVal
	} else {
		delete(s.dirty, ch.key)
	}
}

// balanceChange tracks balance change
type balanceChange struct {
	key      string // verkle key (balanceKey)
	prevVal  []byte
	prevDirt bool
}

func (ch balanceChange) revert(s *StateDB) {
	if ch.prevDirt {
		s.dirty[ch.key] = ch.prevVal
	} else {
		delete(s.dirty, ch.key)
	}
}

// General verifiable change for any dirty map update
type dirtyChange struct {
	key      string
	prevVal  []byte
	prevDirt bool
}

func (ch dirtyChange) revert(s *StateDB) {
	if ch.prevDirt {
		s.dirty[ch.key] = ch.prevVal
	} else {
		delete(s.dirty, ch.key)
	}
}

// codeChange
type codeChange struct {
	addr     common.Address
	prevCode []byte
	prevHash common.Hash
}

func (ch codeChange) revert(s *StateDB) {
	s.code[ch.prevHash] = ch.prevCode // Restore map (though usually additive only)
	// We also need to revert the 'dirty' entry for codehash but that is handled by dirtyChange if we use it consistently.
}

// addLogChange tracks the addition of a log
type addLogChange struct {
	txhash common.Hash
}

func (ch addLogChange) revert(s *StateDB) {
	logs := s.logs[ch.txhash]
	if len(logs) > 0 {
		s.logs[ch.txhash] = logs[:len(logs)-1]
	}
}

// addPreimageChange tracks the addition of a preimage
type addPreimageChange struct {
	hash common.Hash
}

func (ch addPreimageChange) revert(s *StateDB) {
	delete(s.preimages, ch.hash)
}

type refundChange struct {
	prev uint64
}

func (ch refundChange) revert(s *StateDB) {
	s.refund = ch.prev
}
