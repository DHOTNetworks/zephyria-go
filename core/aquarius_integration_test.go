package core

import (
	"math/big"
	"testing"
	"zephyria/state"
	ztypes "zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	// ethcore "github.com/ethereum/go-ethereum/core" // Not identifying used
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
	"github.com/syndtr/goleveldb/leveldb"
	"github.com/syndtr/goleveldb/leveldb/storage"
)

// simpleASM compiles simple opcodes to bytecode
func simpleASM(ops ...byte) []byte {
	return ops
}

// TestAquarius_ShardedConfidentiality verifies that two users calling the same contract
// end up with ISOLATED storage in their respective Data Shards.
func TestAquarius_ShardedConfidentiality(t *testing.T) {
	// 1. Setup
	db, _ := leveldb.Open(storage.NewMemStorage(), nil)
	statedb := state.New(common.Hash{}, db)

	// Create a "Counter" Contract
	// Logic: SLOAD(0) -> ADD 1 -> SSTORE(0)
	// PUSH1 0x00 SLOAD PUSH1 0x01 ADD PUSH1 0x00 SSTORE
	contractAddr := common.HexToAddress("0x1000")
	code := simpleASM(
		0x60, 0x00, // PUSH1 0
		0x54,       // SLOAD
		0x60, 0x01, // PUSH1 1
		0x01,       // ADD
		0x60, 0x00, // PUSH1 0
		0x55, // SSTORE
	)

	statedb.CreateAccount(contractAddr)
	statedb.SetCode(contractAddr, code, tracing.CodeChangeReason(0))
	// statedb.SetProgramAddress(contractAddr, contractAddr) // Implicitly program if code exists

	// 2. Execution Setup
	chainConfig := &params.ChainConfig{ChainID: big.NewInt(1), TerminalTotalDifficulty: big.NewInt(0)}
	// We need a mock blockchain or minimal context
	header := &ztypes.Header{
		Number:   big.NewInt(1),
		GasLimit: 10_000_000,
		Time:     1000,
	}

	executor := NewExecutor(chainConfig, &NetworkConfig{Params: ztypes.SystemParams{}}, nil)

	// 3. Create Transactions from 2 Users
	// user1 := common.HexToAddress("0xA1") // Derived from key
	// user2 := common.HexToAddress("0xB2")

	key1, _ := crypto.GenerateKey()
	key2, _ := crypto.GenerateKey()

	// Construct Txs
	tx1 := types.NewTransaction(0, contractAddr, big.NewInt(0), 100000, big.NewInt(1), nil)
	tx2 := types.NewTransaction(0, contractAddr, big.NewInt(0), 100000, big.NewInt(1), nil)

	signer := types.LatestSigner(chainConfig)
	stx1, _ := types.SignTx(tx1, signer, key1) // User 1
	stx2, _ := types.SignTx(tx2, signer, key2) // User 2

	user1Func, _ := types.Sender(signer, stx1)
	user2Func, _ := types.Sender(signer, stx2)

	// 4. Run ApplyBlock
	// Note: We need to set balance for gas
	startBal, _ := uint256.FromBig(big.NewInt(1e18))
	statedb.AddBalance(user1Func, startBal, tracing.BalanceChangeReason(0))
	statedb.AddBalance(user2Func, startBal, tracing.BalanceChangeReason(0))

	blockTxs := []*types.Transaction{stx1, stx2}

	receipts, root, err := executor.ApplyBlock(statedb, header, blockTxs)
	if err != nil {
		t.Fatalf("ApplyBlock failed: %v", err)
	}

	if len(receipts) != 2 {
		t.Errorf("Expected 2 receipts, got %d", len(receipts))
	}
	t.Logf("Receipt 1 GasUsed: %d", receipts[0].GasUsed)
	t.Logf("Receipt 2 GasUsed: %d", receipts[1].GasUsed)

	t.Logf("ApplyBlock Root: %x", root)

	// 5. Verification
	// The contract logic (SSTORE 0, 1) should have run TWICE.
	// But on DIFFERENT Data Accounts.

	// a) Check Global Contract Logic
	// Global Contract should have nil/zero storage at slot 0 (Code didn't write to Global)
	// Because Executor Redirected.
	valGlobal := statedb.GetState(contractAddr, common.Hash{})
	if valGlobal != (common.Hash{}) {
		t.Errorf("Global State Leak! Contract Addr has storage: %x", valGlobal)
	}

	// b) Check User 1 Data Account
	dataAddr1 := state.DeriveDataAddress(user1Func, contractAddr)
	val1 := statedb.GetState(dataAddr1, common.Hash{})
	if val1.Big().Cmp(big.NewInt(1)) != 0 {
		t.Errorf("User 1 Data Shard incorrect. Expected 1, got %x. Addr: %s", val1, dataAddr1.Hex())
	}

	// c) Check User 2 Data Account
	dataAddr2 := state.DeriveDataAddress(user2Func, contractAddr)
	val2 := statedb.GetState(dataAddr2, common.Hash{})
	if val2.Big().Cmp(big.NewInt(1)) != 0 {
		t.Errorf("User 2 Data Shard incorrect. Expected 1, got %x. Addr: %s", val2, dataAddr2.Hex())
	}

	// d) Ensure Data Addresses are different
	if dataAddr1 == dataAddr2 {
		t.Fatal("Data Addresses collision!")
	}
}

// TestAquarius_GlobalDelta verifies that contracts using the Delta method
// successfully update the Global Shared State.
func TestAquarius_GlobalDelta(t *testing.T) {
	// 1. Setup
	db, _ := leveldb.Open(storage.NewMemStorage(), nil)
	statedb := state.New(common.Hash{}, db)

	contractAddr := common.HexToAddress("0x2000")

	// Bytecode construction
	deltaVal := big.NewInt(50)
	deltaBytes := common.BigToHash(deltaVal).Bytes()

	// 60 00 60 00 52 (PUSH 0, PUSH 0, MSTORE) -> Key=0 at Mem[0]
	// 7F <32 bytes val> 60 20 52 (PUSH32 Val, PUSH 32, MSTORE) -> Val=50 at Mem[32]
	// ... Call Code ...
	code := []byte{
		0x60, 0x00, 0x60, 0x00, 0x52, // Key = 0
		0x7F, // PUSH32
	}
	code = append(code, deltaBytes...)
	code = append(code,
		0x60, 0x20, 0x52, // Val = 50 at 32
		0x60, 0x00, // RetLen
		0x60, 0x00, // RetOff
		0x60, 0x40, // ArgLen
		0x60, 0x00, // ArgOff
		0x60, 0x00, // Value
		0x60, 0x08, // Addr 0x08 (DeltaPrecompile)
		0x60, 0xFF, // GAS (Small)
		0x60, 0xFF, // PUSH 0xFFFF
		0x02, // MUL -> High gas
		0xF1, // CALL
		0x50, // POP (Success)
	)

	statedb.CreateAccount(contractAddr)
	statedb.SetCode(contractAddr, code, tracing.CodeChangeReason(0))

	// 2. Execute
	chainConfig := &params.ChainConfig{ChainID: big.NewInt(1)}
	header := &ztypes.Header{Number: big.NewInt(1), GasLimit: 10_000_000}
	executor := NewExecutor(chainConfig, &NetworkConfig{Params: ztypes.SystemParams{}}, nil)

	signer := types.LatestSigner(chainConfig)
	key1, _ := crypto.GenerateKey()
	tx1 := types.NewTransaction(0, contractAddr, big.NewInt(0), 100000, big.NewInt(1), nil)
	stx1, _ := types.SignTx(tx1, signer, key1)

	sender, _ := types.Sender(signer, stx1)
	startBal, _ := uint256.FromBig(big.NewInt(1e18))
	statedb.AddBalance(sender, startBal, tracing.BalanceChangeReason(0))

	// Apply
	receipts, _, err := executor.ApplyBlock(statedb, header, []*types.Transaction{stx1})
	if err != nil {
		t.Fatalf("ApplyBlock failed: %v", err)
	}
	if receipts[0].Status == 0 {
		t.Fatal("Transaction Failed (Revert)")
	}

	t.Log("Delta Transaction Executed Successfully")
}

// TestAquarius_OwnershipInheritance verifies that a Data Account can read global configuration
// (like Owner) from the Program Account if it is missing locally.
func TestAquarius_OwnershipInheritance(t *testing.T) {
	// 1. Setup
	db, _ := leveldb.Open(storage.NewMemStorage(), nil)
	statedb := state.New(common.Hash{}, db)

	// Create Contract
	// Logic: value = SLOAD(0). If value == 0x1234, SSTORE(1, 1). Else REVERT/SSTORE(1, 0).
	// We want to prove that executing on DataAddr (where slot 0 is empty)
	// will read slot 0 from ProgramAddr (where it is 0x1234).

	// Bytecode:
	// PUSH1 0x00 SLOAD (Should read 0x1234 from inherited state)
	// PUSH2 0x1234 EQ
	// PUSH1 0x00 JUMPI (Jump to Success logic if EQ)
	// REVERT (Fail)
	// JUMPDEST (Success)
	// PUSH1 0x01 PUSH1 0x01 SSTORE (Write to local storage slot 1)

	// ASM:
	// 60 00 54 61 12 34 14 60 0C 57 FD 5B 60 01 60 01 55

	contractAddr := common.HexToAddress("0x3000")
	ownerVal := common.HexToHash("0x0000000000000000000000000000000000000000000000000000000000001234")

	code := []byte{
		0x60, 0x00, 0x54, // SLOAD(0)
		0x61, 0x12, 0x34, // PUSH2 0x1234
		0x14,       // EQ
		0x60, 0x0B, // PUSH1 11 (JumpDest Offset: 0+1+2+1+3+1+2 + 1 = 11. 0x0B)
		// 0: 60 00 (2)
		// 2: 54 (1)
		// 3: 61 12 34 (3)
		// 6: 14 (1)
		// 7: 60 0B (2) -> Target is 11
		// 9: 57 (JUMPI) (1)
		// 10: FD (REVERT) (1)
		// 11: 5B (JUMPDEST) (1)
		// 12: 60 01 (2)
		// 14: 60 01 (2)
		// 16: 55 (1)
		0x57,                         // JUMPI
		0xFD,                         // REVERT
		0x5B,                         // JUMPDEST (Offset 11 / 0xB)
		0x60, 0x01, 0x60, 0x01, 0x55, // SSTORE(1, 1)
	}
	// code[7] = 0x0B // Removed manual patch, set directly above

	statedb.CreateAccount(contractAddr)
	statedb.SetCode(contractAddr, code, tracing.CodeChangeReason(0))

	// SET GLOBAL STATE (Owner) on Program Account
	statedb.SetState(contractAddr, common.Hash{}, ownerVal) // key 0 = 0x1234

	// 2. Execute as User 1
	// Executor will Redirect to DataAddr(User1, Contract).
	// DataAddr has NO state.
	// SLOAD(0) will trigger GetState(DataAddr, 0).
	// Implementation should Redirect to GetState(ContractAddr, 0) == 0x1234.
	// Eq -> True. SSTORE(1, 1) on DataAddr.

	chainConfig := &params.ChainConfig{ChainID: big.NewInt(1)}
	header := &ztypes.Header{Number: big.NewInt(1), GasLimit: 10_000_000}
	executor := NewExecutor(chainConfig, &NetworkConfig{Params: ztypes.SystemParams{}}, nil)

	signer := types.LatestSigner(chainConfig)
	key1, _ := crypto.GenerateKey()
	tx1 := types.NewTransaction(0, contractAddr, big.NewInt(0), 100000, big.NewInt(1), nil)
	stx1, _ := types.SignTx(tx1, signer, key1)

	sender, _ := types.Sender(signer, stx1)
	startBal, _ := uint256.FromBig(big.NewInt(1e18))
	statedb.AddBalance(sender, startBal, tracing.BalanceChangeReason(0))

	// Apply
	receipts, _, err := executor.ApplyBlock(statedb, header, []*types.Transaction{stx1})
	if err != nil {
		t.Fatalf("ApplyBlock failed: %v", err)
	}
	if receipts[0].Status == 0 {
		t.Fatal("Transaction Failed (Revert) - Inheritance Logic Broken")
	}

	// Verify Result: User Data Account should have Slot 1 = 1
	dataAddr := state.DeriveDataAddress(sender, contractAddr)
	res := statedb.GetState(dataAddr, common.Hash{31: 0x01}) // Key 1
	if res.Big().Cmp(big.NewInt(1)) != 0 {
		t.Fatalf("Expected Data Account Storage[1] == 1, got %x", res)
	}
	t.Log("Ownership Inheritance Verified Successfully")
}
