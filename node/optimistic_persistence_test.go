package node

import (
	"math/big"
	"os"
	"testing"
	"time"

	"zephyria/core"
	"zephyria/state"
	ztypes "zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/holiman/uint256"
	"github.com/syndtr/goleveldb/leveldb"
)

func TestOptimisticConsistency(t *testing.T) {
	// 1. Setup Database
	dbPath, _ := os.MkdirTemp("", "zephyria-test-*")
	defer os.RemoveAll(dbPath)
	db, _ := leveldb.OpenFile(dbPath, nil)
	defer db.Close()

	// 2. Setup Identities
	key, _ := crypto.GenerateKey()
	addr := crypto.PubkeyToAddress(key.PublicKey)
	to := common.HexToAddress("0x456")

	// 3. Initialize State & Fund
	s := state.New(common.Hash{}, db)
	initBal := uint256.NewInt(1e18) // 1 ZEE
	s.SetBalance(addr, initBal, 0)

	// Create a dummy contract storage update
	contractAddr := common.HexToAddress("0x789")
	storageKey := common.HexToHash("0xabc")
	storageVal := common.HexToHash("0xdef")
	s.SetState(contractAddr, storageKey, storageVal)

	// Commit initial state
	batch := new(leveldb.Batch)
	root, _ := s.Commit(db, batch)
	db.Write(batch, nil)

	// 4. Create Transaction
	netCfg := core.GetNetworkConfig(core.Devnet)
	signer := ethtypes.LatestSigner(netCfg.ChainConfig())
	tx := ethtypes.NewTransaction(0, to, big.NewInt(1000), 21000, big.NewInt(1e9), nil)
	signedTx, _ := ethtypes.SignTx(tx, signer, key)

	header := &ztypes.Header{
		ParentHash: root,
		Number:     big.NewInt(1),
		Time:       uint64(time.Now().Unix()),
		Coinbase:   common.HexToAddress("0x123"),
		GasLimit:   30_000_000,
		BaseFee:    big.NewInt(1e9),
	}

	// ---------------------------------------------------------
	// PATH A: STANDARD EXECUTION
	// ---------------------------------------------------------
	sStandard := state.New(root, db)
	executor := core.NewExecutor(netCfg.ChainConfig(), netCfg, nil)

	receiptsA, rootA, err := executor.ApplyBlock(sStandard, header, []*ethtypes.Transaction{signedTx})
	if err != nil {
		t.Fatalf("Standard execution failed: %v", err)
	}

	// ---------------------------------------------------------
	// PATH B: OPTIMISTIC EXECUTION (Overlay + Merge)
	// ---------------------------------------------------------
	sOptBase := state.New(root, db)
	overlay := sOptBase.NewOverlay()

	receiptsB, rootB, err := executor.ApplyBlock(overlay, header, []*ethtypes.Transaction{signedTx})
	if err != nil {
		t.Fatalf("Optimistic execution failed: %v", err)
	}

	// ASSERT 1: Pre-merge Equivalence (Overlay Root calculation)
	if rootA != rootB {
		t.Errorf("Root mismatch: Standard %s vs Optimistic Overlay %s", rootA.Hex(), rootB.Hex())
	}

	// Perform Merge
	overlay.Merge()
	rootMerged := sOptBase.IntermediateRoot(false)

	// ASSERT 2: Post-merge Equivalence (Base State updated correctly)
	if rootA != rootMerged {
		t.Errorf("Root mismatch: Standard %s vs Merged %s", rootA.Hex(), rootMerged.Hex())
	}

	// ASSERT 3: Receipt Equivalence
	if len(receiptsA) != len(receiptsB) {
		t.Fatalf("Receipt length mismatch")
	}
	if receiptsA[0].Status != receiptsB[0].Status || receiptsA[0].GasUsed != receiptsB[0].GasUsed {
		t.Errorf("Receipt data mismatch")
	}

	// ---------------------------------------------------------
	// PERSISTENCE CHECK
	// ---------------------------------------------------------
	optBatch := new(leveldb.Batch)
	sOptBase.Commit(db, optBatch)
	db.Write(optBatch, nil)

	// Reopen state from DB
	sFinal := state.New(rootMerged, db)

	// Check balance of receiver
	balTo := sFinal.GetBalance(to)
	if balTo.Uint64() != 1000 {
		t.Errorf("Persistence failed: Receiver balance %d, expected 1000", balTo.Uint64())
	}

	// Check original storage still exists
	val := sFinal.GetState(contractAddr, storageKey)
	if val != storageVal {
		t.Errorf("Persistence failed: Storage value %s, expected %s", val.Hex(), storageVal.Hex())
	}

	// Check incremented nonce of sender
	nonce := sFinal.GetNonce(addr)
	if nonce != 1 {
		t.Errorf("Persistence failed: Sender nonce %d, expected 1", nonce)
	}

	t.Logf("Success: Standard and Optimistic paths are identical and persistent.")
}
