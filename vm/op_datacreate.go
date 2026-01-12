package vm

import (
	"github.com/ethereum/go-ethereum/common"
	"github.com/holiman/uint256"
)

func opDataCreate(pc *uint64, evm *EVM, scope *ScopeContext) ([]byte, error) {
	// Stack: [value, inputOffset, inputSize, salt, programAddress]
	value := scope.Stack.pop()
	offset, size := scope.Stack.pop(), scope.Stack.pop()
	input := scope.Memory.GetCopy(offset.Uint64(), size.Uint64())
	salt := scope.Stack.pop()

	pItem := scope.Stack.pop()
	programAddr := common.BytesToAddress(pItem.Bytes())

	gas := scope.Contract.Gas
	// Execute CreateDataAccount
	ret, addr, leftOverGas, err := evm.CreateDataAccount(scope.Contract.Address(), programAddr, gas, &value, &salt, input)

	scope.Contract.Gas = leftOverGas

	if err != nil {
		scope.Stack.push(new(uint256.Int)) // 0 on failure
	} else {
		// Push Address
		addrInt := new(uint256.Int).SetBytes(addr.Bytes())
		scope.Stack.push(addrInt)
	}

	return ret, nil
}
