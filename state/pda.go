package state

import (
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// TokenProgramID is the fixed address of the Native Token Logic Contract.
// Address: 0x0000000000000000000000000000000000005000
var TokenProgramID = common.HexToAddress("0x0000000000000000000000000000000000005000")

// DerivePDA calculates a Program Derived Address.
// Formula: Keccak256(ProgramID ++ Seeds...) truncated to 20 bytes.
// This provides a deterministic address rooted in the Program's authority.
func DerivePDA(program common.Address, seeds ...[]byte) common.Address {
	data := append([]byte{}, program.Bytes()...)
	for _, seed := range seeds {
		data = append(data, seed...)
	}
	return common.BytesToAddress(crypto.Keccak256(data))
}

// DeriveATA calculates the Associated Token Account (ATA) address
// for a given user (owner) and a specific Token (mint).
// Formula: DerivePDA(TokenProgram, owner, mint)
func DeriveATA(owner common.Address, mint common.Address) common.Address {
	return DerivePDA(TokenProgramID, owner.Bytes(), mint.Bytes())
}
