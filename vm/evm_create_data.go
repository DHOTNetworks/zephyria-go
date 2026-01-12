package vm

import (
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/holiman/uint256"
)

// CreateDataAccount creates a new Data Account linked to a Program.
// Address = Keccak256(0xff ++ sender ++ salt ++ keccak256(programAddress))
// The function creates the account, sets the Program Pointer, transfers value, and invokes the account with input.
func (evm *EVM) CreateDataAccount(caller common.Address, programAddress common.Address, gas uint64, value *uint256.Int, salt *uint256.Int, input []byte) (ret []byte, contractAddr common.Address, leftOverGas uint64, err error) {
	// 1. Calculate Address (Solana-style binding)
	// We bind the address to the Program so one can't deploy a Data Account for a Program one doesn't know.
	// Address = Keccak256(0xff ++ sender ++ salt ++ Keccak256(programAddress))
	progHash := crypto.Keccak256Hash(programAddress.Bytes())
	contractAddr = crypto.CreateAddress2(caller, salt.Bytes32(), progHash.Bytes())

	// Tracing
	if evm.Config.Tracer != nil {
		evm.captureBegin(evm.depth, DATACREATE, caller, contractAddr, input, gas, value.ToBig())
		defer func(startGas uint64) {
			evm.captureEnd(evm.depth, startGas, leftOverGas, ret, err)
		}(gas)
	}

	// Depth Check
	if evm.depth > int(CallCreateDepth) {
		return nil, common.Address{}, gas, ErrDepth
	}
	// Balance Check
	if !evm.Context.CanTransfer(evm.StateDB, caller, value) {
		return nil, common.Address{}, gas, ErrInsufficientBalance
	}

	// Nonce Check/Increment
	nonce := evm.StateDB.GetNonce(caller)
	evm.StateDB.SetNonce(caller, nonce+1, tracing.NonceChangeContractCreator)

	// Access List
	evm.StateDB.AddAddressToAccessList(contractAddr)

	// Collision Check
	if evm.StateDB.GetNonce(contractAddr) != 0 || len(evm.StateDB.GetCode(contractAddr)) > 0 {
		return nil, common.Address{}, 0, ErrContractAddressCollision
	}

	// Create Account
	snapshot := evm.StateDB.Snapshot()
	evm.StateDB.CreateAccount(contractAddr)
	evm.StateDB.SetNonce(contractAddr, 1, tracing.NonceChangeNewContract)

	// SEALEVEL LINKING: Set the Program Pointer
	evm.StateDB.SetProgramAddress(contractAddr, programAddress)

	// Transfer Endowment
	evm.Context.Transfer(evm.StateDB, caller, contractAddr, value)

	// Call "Constructor" (Initialization Logic)
	// We execute the Program Code in the context of the New Data Account.
	// We use evm.Run directly to avoid Double Transfer (evm.Call would transfer value again).

	// Fetch Program Code
	progCode := evm.StateDB.GetCode(programAddress)
	progCodeHash := evm.StateDB.GetCodeHash(programAddress)

	// Setup Contract Context (Similar to evm.create)
	contract := NewContract(caller, contractAddr, value, gas, evm.jumpDests)
	contract.SetCallCode(progCodeHash, progCode)

	// Execute
	ret, err = evm.Run(contract, input, false)
	leftOverGas = contract.Gas

	if err != nil {
		evm.StateDB.RevertToSnapshot(snapshot)
		if err != ErrExecutionReverted {
			leftOverGas = 0
		}
	}

	return ret, contractAddr, leftOverGas, err
}
