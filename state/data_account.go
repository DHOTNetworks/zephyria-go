package state

import (
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// DeriveDataAddress computes the deterministic address for a User's Data Account
// linked to a specific Program (Contract).
// Formula: Keccak256(Sender ++ Program)
// This effectively shards the state: Each user gets their own storage instance for the contract.
func DeriveDataAddress(sender common.Address, program common.Address) common.Address {
	input := append(sender.Bytes(), program.Bytes()...)
	return common.BytesToAddress(crypto.Keccak256(input))
}

// EnsureDataAccount checks if the Data Account exists.
// If not, it creates it and binds it to the Program.
// Returns the Data Address to be used for execution.
func (s *StateDB) EnsureDataAccount(sender common.Address, program common.Address) common.Address {
	dataAddr := DeriveDataAddress(sender, program)

	// Check if already linked
	existingProg := s.GetProgramAddress(dataAddr)
	if existingProg == program {
		return dataAddr
	}

	// If not linked or new, we must bind it.
	// 1. Create Account if empty (implicitly done by setting values, but good to be explicit for tracing/hooks)
	s.CreateAccount(dataAddr)

	// 2. Set Program Dependency
	s.SetProgramAddress(dataAddr, program)

	// 3. Debug/Log (Optional, but helpful for transparency)
	// fmt.Printf(" [Aquarius] Auto-Bound Data Account %s to Program %s for User %s\n", dataAddr.Hex(), program.Hex(), sender.Hex())

	return dataAddr
}

// IsDataAccount checks if the address is acting as a Data Account (has a Program Pointer).
func (s *StateDB) IsDataAccount(addr common.Address) bool {
	return s.GetProgramAddress(addr) != (common.Address{})
}
