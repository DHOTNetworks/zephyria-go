package core

import (
	"errors"
	"math/big"

	vm "zephyria/vm"

	"github.com/ethereum/go-ethereum/common"
)

// DeltaPrecompileAddress is the address of the Delta State precompile (0x...DD)
var DeltaPrecompileAddress = common.HexToAddress("0x00000000000000000000000000000000000000DD")

// DeltaPrecompile implements vm.StatefulPrecompiledContract AND vm.PrecompiledContract
type DeltaPrecompile struct{}

func (p *DeltaPrecompile) RequiredGas(input []byte) uint64 {
	// Fixed gas cost for a delta update.
	return 5000
}

// Run satisfies the vm.PrecompiledContract interface but shouldn't be called directly by EVM
// if it detects StatefulPrecompiledContract.
func (p *DeltaPrecompile) Run(input []byte) ([]byte, error) {
	return nil, errors.New("DeltaPrecompile must be called via RunStateful")
}

func (p *DeltaPrecompile) RunStateful(input []byte, statedb vm.StateDB) ([]byte, error) {
	// Input format: [Key (32 bytes)] [Delta (32 bytes - signed int256)]
	if len(input) < 64 {
		return nil, errors.New("input too short: expected 64 bytes (key + delta)")
	}

	key := input[:32]
	deltaBytes := input[32:64]

	// Convert deltaBytes to big.Int (Signed)
	delta := new(big.Int).SetBytes(deltaBytes)

	// Handle Two's Complement for negative numbers
	if deltaBytes[0]&0x80 != 0 {
		// It is negative.
		// Value = delta - 2^256
		two256 := new(big.Int).Lsh(big.NewInt(1), 256)
		delta.Sub(delta, two256)
	}

	statedb.AddStateDelta(key, delta)

	return []byte{1}, nil
}

func (p *DeltaPrecompile) Name() string {
	return "DELTA_UPDATE"
}
