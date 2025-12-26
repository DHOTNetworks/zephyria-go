package state

import (
	"fmt"
	"math/big"
	"sync"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/stateless"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
	"github.com/ethereum/go-ethereum/trie/utils"
	"github.com/ethereum/go-verkle"
	"github.com/holiman/uint256"
	"github.com/syndtr/goleveldb/leveldb"
	"github.com/syndtr/goleveldb/leveldb/util"
)

// StateDB implements the EVM StateDB interface using a Verkle Tree.
type StateDB struct {
	tree    verkle.VerkleNode
	rwMutex sync.RWMutex
	db      *leveldb.DB // Persistent storage

	// Cache for code because Verkle normally stores code implementation logic differently (chunking).
	// For PoC, we store code hash in tree, and code in a map (or simplified).
	code map[common.Hash][]byte

	// Logs
	logs map[common.Hash][]*types.Log

	// Preimages
	preimages map[common.Hash][]byte

	// Access lists (mocked)
	accessList *accessList

	transientStorage map[common.Address]map[common.Hash]common.Hash

	// Parallel Execution Logic
	parent *StateDB
	dirty  map[string][]byte // Key -> Value (buffer for overlay)
	lock   sync.RWMutex      // For concurrent access to overlay fields if needed (though lanes are single-threaded)
}

type accessList struct {
	// simplified
}

func New(root common.Hash, db *leveldb.DB) *StateDB {
	s := &StateDB{
		db:               db,
		code:             make(map[common.Hash][]byte),
		logs:             make(map[common.Hash][]*types.Log),
		preimages:        make(map[common.Hash][]byte),
		transientStorage: make(map[common.Address]map[common.Hash]common.Hash),
		dirty:            make(map[string][]byte),
	}

	// PoC Persistence: Always reconstruct tree from DB keys
	// Since we only save leaf values in 'v' prefix, we must replay them to rebuild the tree.
	s.tree = verkle.New()

	if s.db != nil {
		iter := s.db.NewIterator(util.BytesPrefix([]byte("v")), nil)
		count := 0
		for iter.Next() {
			// Key is v + actualKey
			k := iter.Key()
			if len(k) < 1 {
				continue
			}
			realKey := k[1:]
			val := iter.Value()
			// Insert into tree
			s.tree.Insert(realKey, val, s.resolver)
			count++
		}
		iter.Release()
		fmt.Printf("Reconstructed State Tree from %d DB entries.\n", count)
	}

	return s
}

// NewOverlay creates a new state that reads from 's' but writes locally.
func (s *StateDB) NewOverlay() *StateDB {
	return &StateDB{
		parent:           s,
		db:               s.db, // Share DB (read-only for overlay essentially)
		dirty:            make(map[string][]byte),
		code:             make(map[common.Hash][]byte),
		logs:             make(map[common.Hash][]*types.Log),
		preimages:        make(map[common.Hash][]byte),
		transientStorage: make(map[common.Address]map[common.Hash]common.Hash),
		tree:             nil, // Overlay doesn't own a tree
	}
}

// Merge flushes changes from this overlay back to the parent.
func (s *StateDB) Merge() {
	if s.parent == nil {
		return
	}
	// Merge dirty keys
	for k, v := range s.dirty {
		s.parent.setVerkleValue([]byte(k), v)
	}
	// Merge code
	for k, v := range s.code {
		s.parent.code[k] = v
	}
	// Merge logs
	for k, v := range s.logs {
		s.parent.logs[k] = append(s.parent.logs[k], v...)
	}
	// Merge preimages
	for k, v := range s.preimages {
		s.parent.preimages[k] = v
	}
}

// Low-level Verkle Helpers

func (s *StateDB) resolver(key []byte) ([]byte, error) {
	if s.db == nil {
		return nil, fmt.Errorf("no db")
	}
	// Prefix 'v' used in Commit
	dbKey := append([]byte("v"), key...)
	data, err := s.db.Get(dbKey, nil)
	return data, err
}

func (s *StateDB) getVerkleValue(key []byte) []byte {
	// Check overlay dirty set first
	if s.dirty != nil {
		if val, ok := s.dirty[string(key)]; ok {
			return val
		}
	}

	// If overlay, delegate to parent
	if s.parent != nil {
		return s.parent.getVerkleValue(key)
	}

	// Base state lookup
	if s.tree == nil {
		return nil
	}

	// Resolver is nil for memory-only tree -> changed to s.resolver
	val, err := s.tree.Get(key, s.resolver)
	if err != nil {
		// handle error
		return nil
	}
	return val
}

func (s *StateDB) setVerkleValue(key []byte, value []byte) {
	// Always write to dirty map for persistence tracking
	s.dirty[string(key)] = value

	// If overlay, we are done (writes are buffered in dirty)
	if s.parent != nil {
		return
	}

	// Base mode: Update the actual memory tree for execution
	if s.tree != nil {
		s.tree.Insert(key, value, s.resolver)
	}
}

// Commit flushes the state changes to the given database batch.
func (s *StateDB) Commit(db *leveldb.DB, batch *leveldb.Batch) (common.Hash, error) {
	// 1. Write dirty values to DB
	for k, v := range s.dirty {
		// Prefix 'v' for verkle/state data
		dbKey := append([]byte("v"), []byte(k)...)
		batch.Put(dbKey, v)
	}

	// 2. Clear dirty set
	s.dirty = make(map[string][]byte)

	// 3. Return Root
	return s.IntermediateRoot(false), nil
}

// Address to Stem/Key Mapping
// We use 31 bytes of hash as stem.
// Suffixes:
// 0x00: Nonce (re-encoded)
// 0x01: Balance
// 0x02: CodeHash
// Storage: Different stem.

func accountStem(addr common.Address) []byte {
	h := crypto.Keccak256Hash(addr.Bytes())
	return h[:31]
}

func nonceKey(addr common.Address) []byte {
	return append(accountStem(addr), 0x00)
}

func balanceKey(addr common.Address) []byte {
	return append(accountStem(addr), 0x01)
}

func codeHashKey(addr common.Address) []byte {
	return append(accountStem(addr), 0x02)
}

// Prefetch warms up the cache for the given addresses.
func (s *StateDB) Prefetch(addrs []common.Address) {
	s.rwMutex.RLock()
	defer s.rwMutex.RUnlock()

	for _, addr := range addrs {
		// Just accessing the values triggers the underlying tree/DB load
		s.getVerkleValue(nonceKey(addr))
		s.getVerkleValue(balanceKey(addr))
		s.getVerkleValue(codeHashKey(addr))
	}
}

// Core EVM Methods

func (s *StateDB) CreateAccount(addr common.Address) {
	// No-op in Verkle usually, just setting values creates it.
}

func (s *StateDB) CreateContract(addr common.Address) {
	// No-op for PoC
}

// addBalance is a helper to update an account's balance.
func (s *StateDB) addBalance(addr common.Address, amount *uint256.Int) uint256.Int {
	cur := s.GetBalance(addr)
	newBal := new(uint256.Int).Add(cur, amount)
	s.SetBalance(addr, newBal, tracing.BalanceChangeReason(0)) // Reason is set by caller
	return *newBal
}

// AddBalance adds to the balance of an account.
func (s *StateDB) AddBalance(addr common.Address, amount *uint256.Int, reason tracing.BalanceChangeReason) uint256.Int {
	return s.addBalance(addr, amount)
}

// AddBalanceReward adds a block reward (convenience wrapper).
func (s *StateDB) AddBalanceReward(addr common.Address, amount *uint256.Int) {
	s.AddBalance(addr, amount, tracing.BalanceChangeReason(0))
}

func (s *StateDB) SubBalance(addr common.Address, amount *uint256.Int, reason tracing.BalanceChangeReason) uint256.Int {
	neg := new(uint256.Int).Neg(amount)
	return s.addBalance(addr, neg)
}

func (s *StateDB) GetBalance(addr common.Address) *uint256.Int {
	val := s.getVerkleValue(balanceKey(addr))
	if len(val) == 0 {
		return uint256.NewInt(0)
	}
	res := new(uint256.Int)
	res.SetBytes(val)
	return res
}

func (s *StateDB) SetBalance(addr common.Address, amount *uint256.Int, reason tracing.BalanceChangeReason) {
	s.setVerkleValue(balanceKey(addr), amount.Bytes())
}

func (s *StateDB) GetNonce(addr common.Address) uint64 {
	val := s.getVerkleValue(nonceKey(addr))
	if len(val) == 0 {
		return 0
	}
	return new(big.Int).SetBytes(val).Uint64()
}

func (s *StateDB) SetNonce(addr common.Address, nonce uint64, reason tracing.NonceChangeReason) {
	s.setVerkleValue(nonceKey(addr), big.NewInt(int64(nonce)).Bytes())
}

func (s *StateDB) GetCodeHash(addr common.Address) common.Hash {
	val := s.getVerkleValue(codeHashKey(addr))
	if len(val) == 0 {
		return common.Hash{}
	}
	return common.BytesToHash(val)
}

func (s *StateDB) GetCode(addr common.Address) []byte {
	hash := s.GetCodeHash(addr)
	return s.code[hash]
}

func (s *StateDB) SetCode(addr common.Address, code []byte, reason tracing.CodeChangeReason) []byte {
	h := crypto.Keccak256Hash(code)
	s.setVerkleValue(codeHashKey(addr), h.Bytes())
	s.code[h] = code
	return code
}

func (s *StateDB) GetCodeSize(addr common.Address) int {
	return len(s.GetCode(addr))
}

// GetLogs returns the logs for a specific transaction hash.
func (s *StateDB) GetLogs(txHash common.Hash) []*types.Log {
	return s.logs[txHash]
}

// Storage
// Key = Hash(Addr ++ Key) for simplicity in PoC
func storageKey(addr common.Address, key common.Hash) []byte {
	input := append(addr.Bytes(), key.Bytes()...)
	return crypto.Keccak256(input) // 32 bytes
}

func (s *StateDB) GetState(addr common.Address, key common.Hash) common.Hash {
	// Verkle requires 32 byte key.
	// EIP-4762: storage slots are grouped.
	// PoC: Just map H(addr, key) -> Value.
	// But H(addr, key) is 32 bytes. We need to split into Stem (31) + Suffix (1).
	// We'll use the first 31 bytes as stem, last byte as suffix.
	sk := storageKey(addr, key)
	val := s.getVerkleValue(sk) // sk is 32 bytes, fits Insert?
	// Wait, Insert(key, value) expects key of length StemSize+1 (32).
	if len(val) == 0 {
		return common.Hash{}
	}
	return common.BytesToHash(val)
}

func (s *StateDB) SetState(addr common.Address, key common.Hash, value common.Hash) common.Hash {
	oldVal := s.GetState(addr, key) // get old for return (simulated)
	sk := storageKey(addr, key)
	s.setVerkleValue(sk, value.Bytes())
	return oldVal
}

// Boilerplate stubs for StateDB interface

func (s *StateDB) SelfDestruct(addr common.Address) uint256.Int {
	// Return balance destroyed
	bal := s.GetBalance(addr)
	// tracing.BalanceChangeReason might be int or checking constants.
	// Trying unsafe cast or reasonable guess.
	// Recent Geth: it is type BalanceChangeReason uint8
	s.SetBalance(addr, uint256.NewInt(0), tracing.BalanceChangeReason(0))
	return *bal
}
func (s *StateDB) SelfDestruct6780(addr common.Address) (uint256.Int, bool) {
	// EIP-6780 behavior: only destroy if created in same tx.
	// For PoC: treat same as SelfDestruct or no-op/clearing.
	return s.SelfDestruct(addr), true
}

func (s *StateDB) HasSelfDestructed(addr common.Address) bool { return false }
func (s *StateDB) Suicide(addr common.Address) bool           { return true } // Legacy support if needed
func (s *StateDB) HasSuicided(addr common.Address) bool       { return false }
func (s *StateDB) Exist(addr common.Address) bool             { return true }
func (s *StateDB) Empty(addr common.Address) bool {
	return s.GetBalance(addr).Sign() == 0 && s.GetNonce(addr) == 0 && len(s.GetCode(addr)) == 0
}
func (s *StateDB) Prepare(rules params.Rules, sender, coinbase common.Address, dst *common.Address, precompiles []common.Address, list types.AccessList) {
}
func (s *StateDB) AddressInAccessList(addr common.Address) bool { return true }
func (s *StateDB) SlotInAccessList(addr common.Address, slot common.Hash) (addressOk bool, slotOk bool) {
	return true, true
}
func (s *StateDB) AddAddressToAccessList(addr common.Address)                {}
func (s *StateDB) AddSlotToAccessList(addr common.Address, slot common.Hash) {}
func (s *StateDB) RevertToSnapshot(revid int)                                {}
func (s *StateDB) Snapshot() int                                             { return 0 }
func (s *StateDB) AddLog(log *types.Log) {
	// store logs
}
func (s *StateDB) AddPreimage(hash common.Hash, preimage []byte) {}
func (s *StateDB) ForEachStorage(addr common.Address, cb func(key, value common.Hash) bool) error {
	return nil
}
func (s *StateDB) GetCommittedState(addr common.Address, key common.Hash) common.Hash {
	return s.GetState(addr, key)
}
func (s *StateDB) GetStateAndCommittedState(addr common.Address, key common.Hash) (common.Hash, common.Hash) {
	val := s.GetState(addr, key)
	return val, val
}
func (s *StateDB) GetStorageRoot(addr common.Address) common.Hash { return common.Hash{} }
func (s *StateDB) GetRefund() uint64                              { return 0 }
func (s *StateDB) AddRefund(gas uint64)                           {}
func (s *StateDB) SubRefund(gas uint64)                           {}

// Transient storage
func (s *StateDB) GetTransientState(addr common.Address, key common.Hash) common.Hash {
	if m, ok := s.transientStorage[addr]; ok {
		return m[key]
	}
	return common.Hash{}
}
func (s *StateDB) SetTransientState(addr common.Address, key, value common.Hash) {
	if _, ok := s.transientStorage[addr]; !ok {
		s.transientStorage[addr] = make(map[common.Hash]common.Hash)
	}
	s.transientStorage[addr][key] = value
}

// Finalization
func (s *StateDB) Finalise(deleteEmptyObjects bool) {}
func (s *StateDB) IntermediateRoot(deleteEmptyObjects bool) common.Hash {
	if s.parent != nil {
		return s.parent.IntermediateRoot(deleteEmptyObjects)
	}
	if s.tree == nil {
		return common.Hash{}
	}
	// Return Verkle Root
	s.tree.Commit()
	vRoot := s.tree.Hash() // returns *Fr
	// Convert Fr map field to common.Hash (32 bytes)
	// Fr is 32 bytes (scalar field).
	bytes := vRoot.BytesLE()
	return common.BytesToHash(bytes[:])
}

// Error handling interface
func (s *StateDB) Error() error   { return nil }
func (s *StateDB) Database() any  { return nil }
func (s *StateDB) Copy() *StateDB { return nil } // simplified

// New methods for interface compliance
func (s *StateDB) PointCache() *utils.PointCache { return nil }
func (s *StateDB) Witness() *stateless.Witness   { return nil }
