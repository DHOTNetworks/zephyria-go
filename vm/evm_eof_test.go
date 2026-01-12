package vm

import (
	"math/big"
	"testing"
	"time"

	"zephyria/state"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/holiman/uint256"
)

// Wrapper for creating an EVM for testing
func NewTestEVM(stateDB StateDB) *EVM {
	blockCtx := BlockContext{
		BlockNumber: big.NewInt(1),
		Time:        uint64(time.Now().Unix()),
		Difficulty:  big.NewInt(0),
		GasLimit:    10000000,
		CanTransfer: func(db StateDB, addr common.Address, amount *uint256.Int) bool {
			return true
		},
		Transfer: func(db StateDB, sender, recipient common.Address, amount *uint256.Int) {
			// Stub
		},
		GetHash: func(n uint64) common.Hash {
			return common.Hash{}
		},
	}

	evm := NewEVM(blockCtx, stateDB, Config{})
	evm.TxContext = TxContext{
		Origin:   common.Address{},
		GasPrice: big.NewInt(1),
	}

	// Manually set table to Cancun which we updated to include EOF
	table := newCancunInstructionSet()
	evm.table = &table

	return evm
}

func TestEOFCreateOpcode(t *testing.T) {
	// Setup StateDB
	s := state.New(common.Hash{}, nil)
	evm := NewTestEVM(s)

	// Contract Address
	sender := common.Address{1}
	evm.StateDB.AddBalance(sender, uint256.NewInt(10000000000), tracing.BalanceIncreaseGenesisBalance)

	// Create a contract that uses EOFCREATE
	// EOFCREATE (0xec)
	// Arguments on stack: init_idx, endowment, salt, data_offset, data_size

	// Bytecode:
	// PUSH1 0 (data_size)
	// PUSH1 0 (data_offset)
	// PUSH1 0 (salt)
	// PUSH1 0 (endowment)
	// PUSH1 0 (init_idx)
	// EOFCREATE
	code := []byte{
		byte(PUSH1), 0x00,
		byte(PUSH1), 0x00,
		byte(PUSH1), 0x00,
		byte(PUSH1), 0x00,
		byte(PUSH1), 0x00,
		byte(EOFCREATE),
	}

	ret, _, _, err := evm.Create(sender, code, 100000, uint256.NewInt(0))
	if err != nil {
		t.Fatalf("Failed to execute EOFCREATE: %v", err)
	}

	_ = ret
}
