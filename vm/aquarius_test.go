package vm

import (
	"math/big"
	"testing"
	"zephyria/state"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

func TestAquarius_DataAccount(t *testing.T) {
	statedb := state.New(common.Hash{}, nil)

	// Bytecode: 60 42 60 00 55 00 (PUSH1 0x42, PUSH1 0x00, SSTORE, STOP)
	progAddr := common.BytesToAddress([]byte{0xAA})
	progCode := []byte{
		byte(PUSH1), 0x42,
		byte(PUSH1), 0x00,
		byte(SSTORE),
		byte(STOP),
	}
	statedb.CreateAccount(progAddr)
	statedb.SetCode(progAddr, progCode, tracing.CodeChangeReason(0))

	// EIP-2929/2930 requires AccessList to be initialized
	statedb.Prepare(params.Rules{IsBerlin: true, IsShanghai: true}, common.Address{}, common.Address{}, nil, nil, nil)

	dataAddr := common.BytesToAddress([]byte{0xDA})
	statedb.CreateAccount(dataAddr)
	statedb.SetProgramAddress(dataAddr, progAddr)

	if len(statedb.GetCode(dataAddr)) == 0 {
		t.Fatalf("Data account SHOULD return Program Code due to redirection")
	}

	evm := NewEVM(BlockContext{
		BlockNumber: big.NewInt(1),
		Time:        1000,
		GasLimit:    10000000,
		CanTransfer: func(StateDB, common.Address, *uint256.Int) bool { return true },
		Transfer:    func(StateDB, common.Address, common.Address, *uint256.Int) {},
		GetHash:     func(uint64) common.Hash { return common.Hash{} },
	}, statedb, Config{})

	caller := common.Address{}
	input := []byte{}
	gas := uint64(100000)
	value := new(uint256.Int)

	_, _, err := evm.Call(caller, dataAddr, input, gas, value)
	if err != nil {
		t.Fatalf("Call failed: %v", err)
	}

	slot0 := statedb.GetState(dataAddr, common.Hash{})
	expected := common.BigToHash(big.NewInt(0x42))
	if slot0 != expected {
		t.Errorf("Data Account storage not updated. Got %x, want %x", slot0, expected)
	}
}

func TestAquarius_OpDataCreate(t *testing.T) {
	statedb := state.New(common.Hash{}, nil)
	// Prepare Access List (Required for EIP-2929)
	statedb.Prepare(params.Rules{IsBerlin: true, IsShanghai: true}, common.Address{}, common.Address{}, nil, nil, nil)

	// 1. Program Account (0xAA)
	// Code: PUSH1 0x42 PUSH1 0x00 SSTORE
	progAddr := common.BytesToAddress([]byte{0xAA})
	progCode := []byte{
		byte(PUSH1), 0x42,
		byte(PUSH1), 0x00,
		byte(SSTORE),
		byte(STOP),
	}
	statedb.CreateAccount(progAddr)
	statedb.SetCode(progAddr, progCode, tracing.CodeChangeReason(0))

	// 2. Factory Account (0xFA)
	// Code:
	// PUSH1 0xAA (Prog)
	// PUSH1 0x01 (Salt)
	// PUSH1 0x00 (Len)
	// PUSH1 0x00 (Offset)
	// PUSH1 0x00 (Value)
	// DATACREATE
	// POP (Address)
	factoryAddr := common.BytesToAddress([]byte{0xFA})
	factoryCode := []byte{
		byte(PUSH1), 0xAA, // Prog
		byte(PUSH1), 0x01, // Salt
		byte(PUSH1), 0x00, // Len
		byte(PUSH1), 0x00, // Offset
		byte(PUSH1), 0x00, // Value
		byte(DATACREATE),
		byte(POP),
		byte(STOP),
	}
	statedb.CreateAccount(factoryAddr)
	statedb.SetCode(factoryAddr, factoryCode, tracing.CodeChangeReason(0))
	statedb.SetBalance(factoryAddr, uint256.NewInt(10000000), tracing.BalanceChangeUnspecified)

	// 3. EVM Setup
	evm := NewEVM(BlockContext{
		BlockNumber: big.NewInt(1),
		Time:        1000,
		GasLimit:    10000000,
		CanTransfer: func(StateDB, common.Address, *uint256.Int) bool { return true },
		Transfer:    func(StateDB, common.Address, common.Address, *uint256.Int) {},
		GetHash:     func(uint64) common.Hash { return common.Hash{} },
	}, statedb, Config{})

	// 4. Trace (Optional)
	// evm.Config.Tracer = tracing.NewStandardTracer(...)

	// 5. Call Factory
	caller := common.Address{} // External caller
	input := []byte{}
	gas := uint64(200000)
	value := new(uint256.Int)

	_, _, err := evm.Call(caller, factoryAddr, input, gas, value)
	if err != nil {
		t.Fatalf("Factory execution failed: %v", err)
	}

	// 6. Verify Data Account
	// Address = Create2(Factory, Salt, Keccak(Prog))
	salt := common.Hash{31: 0x01} // 0x0...01
	progHash := crypto.Keccak256Hash(progAddr.Bytes())
	expectedDataAddr := crypto.CreateAddress2(factoryAddr, salt, progHash.Bytes())

	if !statedb.Exist(expectedDataAddr) {
		t.Fatalf("Data Account %x not created", expectedDataAddr)
	}

	// 7. Verify Linking
	p := statedb.GetProgramAddress(expectedDataAddr)
	if p != progAddr {
		t.Errorf("Program Address mismatch. Got %x, want %x", p, progAddr)
	}

	// 8. Verify Constructor Execution (Storage)
	slot0 := statedb.GetState(expectedDataAddr, common.Hash{})
	expectedStorage := common.BigToHash(big.NewInt(0x42))
	if slot0 != expectedStorage {
		t.Errorf("Constructor did not run? Storage[0] = %x, want %x", slot0, expectedStorage)
	}
}
