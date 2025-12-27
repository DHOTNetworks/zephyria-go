package vm

import (
	"github.com/ethereum/go-ethereum/common"
	ethcore "github.com/ethereum/go-ethereum/core"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/params"
)

// ZephyriaEVM wraps the Geth EVM to provide a stable interface.
type ZephyriaEVM struct {
	evm *vm.EVM
}

// New creates a new EVM instance with Zephyria-specific context.
func New(
	header *types.Header, // We accept Geth header type for compatibility
	chainConfig *params.ChainConfig,
	stateDB vm.StateDB,
	getHash func(uint64) common.Hash,
) *ZephyriaEVM {

	// Construct BlockContext
	blockCtx := vm.BlockContext{
		CanTransfer: ethcore.CanTransfer,
		Transfer:    ethcore.Transfer,
		GetHash:     getHash,
		Coinbase:    header.Coinbase,
		BlockNumber: header.Number,
		Time:        header.Time,
		Difficulty:  header.Difficulty,
		GasLimit:    header.GasLimit,
		BaseFee:     header.BaseFee,
	}

	// TxContext is usually set per-tx, but NewEVM takes it.
	// We'll use a dummy or let ApplyMessage set it.
	// Actually NewEVM takes TxContext? No, it takes BlockContext and TxContext is part of NewEVM return if using old version,
	// or separate in newer versions.
	// Modern Geth: NewEVM(BlockContext, TxContext, StateDB, ChainConfig, Config)
	// Relax limits via vendor patch for MaxCodeSize
	evmConfig := vm.Config{}

	evmInstance := vm.NewEVM(blockCtx, stateDB, chainConfig, evmConfig)
	return &ZephyriaEVM{evm: evmInstance}
}

// ApplyMessage executes a message on the EVM.
func (e *ZephyriaEVM) ApplyMessage(msg *ethcore.Message, gp *ethcore.GasPool) (*ethcore.ExecutionResult, error) {
	return ethcore.ApplyMessage(e.evm, msg, gp)
}
