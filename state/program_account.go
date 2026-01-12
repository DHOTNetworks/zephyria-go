package state

import (
	"github.com/ethereum/go-ethereum/common"
)

// IsProgramAccount verifies if the address is a Program Account (Contract).
// A Program Account is defined as an account that has executable bytecode.
// In the Aquarius model, we treat any Legacy Contract as a "Program Account"
// that can have multiple "Data Accounts" bound to it.
func (s *StateDB) IsProgramAccount(addr common.Address) bool {
	// Optimization: check code hash first to avoid loading full code
	hash := s.GetCodeHash(addr)
	return hash != (common.Hash{}) && hash != emptyCodeHash
}

// emptyCodeHash helper (standard keccak of empty string)
var emptyCodeHash = common.HexToHash("0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

// ResolveExecutionTarget determines the correct context for execution.
// If 'to' is a Program Account, it derives the correct Data Account context for 'sender'.
// If 'to' is EOA or already a Data Account, it returns it as is.
func (s *StateDB) ResolveExecutionTarget(sender common.Address, to common.Address) (context common.Address, program common.Address, isRedirect bool) {
	// 1. If it's already a Data Account (explicit call to shard), execute there.
	if s.IsDataAccount(to) {
		prog := s.GetProgramAddress(to)
		return to, prog, false
	}

	// 2. If it's a Program Account (Contract), we redirect to User's Data Shard.
	if s.IsProgramAccount(to) {
		dataAddr := s.EnsureDataAccount(sender, to)
		return dataAddr, to, true
	}

	// 3. EOA or Empty: No redirection.
	return to, common.Address{}, false
}
