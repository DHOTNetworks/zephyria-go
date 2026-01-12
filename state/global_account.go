package state

import "github.com/ethereum/go-ethereum/common"

// GetGlobalAddress returns the address of the Global State Account for a given Program.
// In the Aquarius model, the Global State Account IS the Program Account itself.
// It stores shared data (e.g., config, total supply) that cannot be sharded.
// This function ensures explicitly that we are targeting the global contract state.
func GetGlobalAddress(program common.Address) common.Address {
	return program
}

// IsGlobalAccount checks if the address is a Program Account effectively acting as a Global State container.
// This is effectively synonymous with IsProgramAccount in our current model,
// but semantically distinct: it represents the "Shared State" role of the address.
func (s *StateDB) IsGlobalAccount(addr common.Address) bool {
	// If it has code, it's a Program / Global Account.
	return s.IsProgramAccount(addr)
}

// EnsureGlobalAccount verifies that the address is a valid Global Account (Contract).
// It ensures the account exists and has code.
func (s *StateDB) EnsureGlobalAccount(addr common.Address) bool {
	return s.Exist(addr) && s.IsProgramAccount(addr)
}

// GetGlobalState retrieves a value from the Global State explicitly.
// This bypasses any potential sharding redirection logic if used within the VM (conceptually),
// although the underlying StateDB.GetState requires the correct address.
func (s *StateDB) GetGlobalState(program common.Address, key common.Hash) common.Hash {
	return s.GetState(program, key)
}

// SetGlobalState writes a value to the Global State explicitly.
// Warning: Usage of this in parallel execution without Commutative properties (Delta)
// will cause serialization or conflicts.
func (s *StateDB) SetGlobalState(program common.Address, key common.Hash, value common.Hash) {
	s.SetState(program, key, value)
}
