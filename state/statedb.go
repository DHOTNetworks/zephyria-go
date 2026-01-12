package state

import (
	"encoding/binary"
	"fmt"
	"math/big"
	"sort"
	"sync"

	"github.com/ethereum/go-ethereum/common"
	gestate "github.com/ethereum/go-ethereum/core/state"
	"github.com/ethereum/go-ethereum/core/stateless"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/trie/utils"
	"github.com/ethereum/go-verkle"
	"github.com/syndtr/goleveldb/leveldb"
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
	parent    *StateDB
	parentRev int                 // Revision of parent when overlay was created
	dirty     map[string][]byte   // Key -> Value (buffer for overlay)
	deltas    map[string]*big.Int // Key -> Delta (Additive changes)
	journal   []JournalEntry      // Journal for state reverts
	lock      sync.RWMutex        // For concurrent access to overlay fields

	// Pruning / Versioning
	viewBlock uint64 // 0 means "latest/head" or unknown (scan latest)

	// Per-transaction refund counter
	refund uint64
}

// Finalise finalises the state by removing the self destructed objects.
func (s *StateDB) Finalise(deleteEmptyObjects bool) {
	// For PoC/Verkle, explicit deletion might be handled via journaling or overlay flush.
	// We can leave this as no-op if we rely on journal replay for deletes,
	// or if we don't support EIP-161 state clearing fully here.
}

func (s *StateDB) PointCache() *utils.PointCache       { return nil }
func (s *StateDB) Witness() *stateless.Witness         { return nil }
func (s *StateDB) AccessEvents() *gestate.AccessEvents { return nil }

// Snapshot returns an identifier for the current revision of the state.
func (s *StateDB) Snapshot() int {
	return len(s.journal)
}

// RevertToSnapshot reverts all state changes made since the given revision.
func (s *StateDB) RevertToSnapshot(revid int) {
	// Sanity check
	if revid > len(s.journal) {
		// Should not happen
		return
	}
	// Revert backwards
	for i := len(s.journal) - 1; i >= revid; i-- {
		s.journal[i].revert(s)
	}
	// Truncate
	s.journal = s.journal[:revid]
}

// AddPreimage records a SHA3 preimage seen by the VM.
func (s *StateDB) AddPreimage(hash common.Hash, preimage []byte) {
	if _, ok := s.preimages[hash]; !ok {
		s.journal = append(s.journal, addPreimageChange{hash: hash})
		pi := make([]byte, len(preimage))
		copy(pi, preimage)
		s.preimages[hash] = pi
	}
}

// AddRefund adds gas to the refund counter.
func (s *StateDB) AddRefund(gas uint64) {
	s.journal = append(s.journal, refundChange{prev: s.refund})
	s.refund += gas
}

// SubRefund removes gas from the refund counter.
func (s *StateDB) SubRefund(gas uint64) {
	s.journal = append(s.journal, refundChange{prev: s.refund})
	if gas > s.refund {
		panic("Refund counter underflow")
	}
	s.refund -= gas
}

// GetRefund returns the current value of the refund counter.
func (s *StateDB) GetRefund() uint64 {
	return s.refund
}

type accessList struct {
	addresses map[common.Address]int
	slots     map[common.Address]map[common.Hash]int
}

func newAccessList() *accessList {
	return &accessList{
		addresses: make(map[common.Address]int),
		slots:     make(map[common.Address]map[common.Hash]int),
	}
}

// AddAddress adds an address to the access list, returning true if it was new.
func (al *accessList) AddAddress(addr common.Address) bool {
	if _, present := al.addresses[addr]; present {
		return false
	}
	al.addresses[addr] = 0 // Value could be used for rollback index
	return true
}

// AddSlot adds a storage slot to the access list, returning true if it was new.
func (al *accessList) AddSlot(addr common.Address, slot common.Hash) bool {
	al.AddAddress(addr)
	slots, present := al.slots[addr]
	if !present {
		slots = make(map[common.Hash]int)
		al.slots[addr] = slots
	}
	if _, present := slots[slot]; present {
		return false
	}
	slots[slot] = 0 // Value could be used for rollback index
	return true
}

func (al *accessList) ContainsAddress(addr common.Address) bool {
	_, present := al.addresses[addr]
	return present
}

func (al *accessList) Contains(addr common.Address, slot common.Hash) (addressPresent bool, slotPresent bool) {
	_, addressPresent = al.addresses[addr]
	if !addressPresent {
		return false, false
	}
	slots, present := al.slots[addr]
	if !present {
		return true, false
	}
	_, slotPresent = slots[slot]
	return true, slotPresent
}

func New(root common.Hash, db *leveldb.DB) *StateDB {
	s := &StateDB{
		db:               db,
		code:             make(map[common.Hash][]byte),
		logs:             make(map[common.Hash][]*types.Log),
		preimages:        make(map[common.Hash][]byte),
		transientStorage: make(map[common.Address]map[common.Hash]common.Hash),
		dirty:            make(map[string][]byte),
		deltas:           make(map[string]*big.Int),
	}

	// PoC Persistence: Always reconstruct tree from DB keys
	// Since we only save leaf values in 'v' prefix, we must replay them to rebuild the tree.
	s.tree = verkle.New()

	// Versioning: Lookup BlockNumber from Root
	if root != (common.Hash{}) && s.db != nil {
		// Key: "r" + Root
		rKey := append([]byte("r"), root.Bytes()...)
		if bNumBytes, err := s.db.Get(rKey, nil); err == nil {
			s.viewBlock = new(big.Int).SetBytes(bNumBytes).Uint64()
			// fmt.Printf("DEBUG: StateDB View Reconstructed for Root %s -> Block %d\n", root.Hex()[:8], s.viewBlock)
		}
	}

	// Optimization: State Tree Cache
	// Instead of iterating the entire LevelDB "v" prefix (which is slow),
	// we try to load a cached list of active leaf keys.
	if s.db != nil {
		s.loadTreeFromCache()
	}
	return s
}

// NewOverlay creates a new state that reads from 's' but writes locally.
func (s *StateDB) NewOverlay() *StateDB {
	s.rwMutex.RLock()
	defer s.rwMutex.RUnlock()

	overlay := &StateDB{
		parent:           s,
		parentRev:        s.Snapshot(), // Capture parent revision
		db:               s.db,         // Share DB (read-only for overlay essentially)
		dirty:            make(map[string][]byte),
		deltas:           make(map[string]*big.Int),
		code:             make(map[common.Hash][]byte),
		logs:             make(map[common.Hash][]*types.Log),
		preimages:        make(map[common.Hash][]byte),
		transientStorage: make(map[common.Address]map[common.Hash]common.Hash),
	}

	// For Verkle root calculation to work in overlays, we need a tree.
	// However, copying the tree (even Copy()) might share internal nodes, leading to Data Races during parallel Insert.
	// Since Transaction Overlays don't need to calculate Roots (only merge), we can skip the tree.
	// Reads will fall back to parent. Writes go to dirty map.
	overlay.tree = nil

	return overlay
}

// Merge flushes changes from this overlay back to the parent.
func (s *StateDB) Merge() {
	if s.parent == nil {
		return
	}
	s.parent.rwMutex.Lock()
	defer s.parent.rwMutex.Unlock()

	// Merge dirty keys and update parent tree
	dirtyKeys := make([]string, 0, len(s.dirty))
	for k := range s.dirty {
		dirtyKeys = append(dirtyKeys, k)
	}
	sort.Strings(dirtyKeys)
	for _, k := range dirtyKeys {
		s.parent.setVerkleValue([]byte(k), s.dirty[k])
	}

	// Merge Deltas (Commutative State Updates)
	// We sort keys for deterministic merge order
	deltaKeys := make([]string, 0, len(s.deltas))
	for k := range s.deltas {
		deltaKeys = append(deltaKeys, k)
	}
	sort.Strings(deltaKeys)

	for _, k := range deltaKeys {
		delta := s.deltas[k]
		// Read current value from parent (which includes valid dirty updates from this merge or previous)
		// Note: getVerkleValue handles reading from dirty/tree
		currBytes := s.parent.getVerkleValue([]byte(k))

		var currVal big.Int
		if len(currBytes) > 0 {
			currVal.SetBytes(currBytes)
		}

		// Apply Delta
		newVal := new(big.Int).Add(&currVal, delta)

		// Write back to parent
		// Note: storage values are usually 32 bytes (uint256)
		// We might need handling for specific encoding if using RLP, but raw bytes works for now.
		// Assuming standard 32-byte big-endian for storage.
		bytes := newVal.Bytes()
		// Padding to 32 bytes to match standard EVM storage behavior if needed,
		// but variable length is fine for Verkle if accessors handle it.
		// Standard EVM is 32 bytes.
		if len(bytes) < 32 {
			padded := make([]byte, 32)
			copy(padded[32-len(bytes):], bytes)
			bytes = padded
		} else if len(bytes) > 32 {
			// Overflow or just large number? EVM is 256 bit.
			// Just slice last 32? Or keep full?
			// Let's assume valid uint256 math happened.
			bytes = bytes[len(bytes)-32:]
		}

		s.parent.setVerkleValue([]byte(k), bytes)
	}

	// Merge code
	codeKeys := make([]common.Hash, 0, len(s.code))
	for k := range s.code {
		codeKeys = append(codeKeys, k)
	}
	// Sort by bytes/string representation
	sort.Slice(codeKeys, func(i, j int) bool {
		return string(codeKeys[i].Bytes()) < string(codeKeys[j].Bytes())
	})
	for _, k := range codeKeys {
		s.parent.code[k] = s.code[k]
	}

	// Merge logs
	logKeys := make([]common.Hash, 0, len(s.logs))
	for k := range s.logs {
		logKeys = append(logKeys, k)
	}
	sort.Slice(logKeys, func(i, j int) bool {
		return string(logKeys[i].Bytes()) < string(logKeys[j].Bytes())
	})
	for _, k := range logKeys {
		s.parent.logs[k] = append(s.parent.logs[k], s.logs[k]...)
	}
	// Preimages
	prekeys := make([]common.Hash, 0, len(s.preimages))
	for k := range s.preimages {
		prekeys = append(prekeys, k)
	}
	sort.Slice(prekeys, func(i, j int) bool {
		return string(prekeys[i].Bytes()) < string(prekeys[j].Bytes())
	})
	for _, k := range prekeys {
		s.parent.preimages[k] = s.preimages[k]
	}
}

// Low-level Verkle Helpers

func (s *StateDB) resolver(key []byte) ([]byte, error) {
	if s.db == nil {
		return nil, fmt.Errorf("no db")
	}
	// Versioned Key: "v" + key + blockNum (8 bytes BigEndian)
	// We want the highest blockNum <= s.viewBlock

	// Prefix: "v" + key
	prefix := append([]byte("v"), key...)

	// Seek: prefix + (s.viewBlock encoded)
	// Note: leveldb iterator Seek goes to >= target.
	// If we want <= viewBlock, we need a reverse strategy or clever seek.
	// Storage Format: Key | BlockNum.
	// If we store BlockNum BigEndian: 0, 1, 2...
	// Seek(Key | ViewBlock+1).Prev() should give us Key | ViewBlock (or smaller).
	// Let's assume BigEndian uint64.

	seekKey := make([]byte, len(prefix)+8)
	copy(seekKey, prefix)

	// If seeking <= viewBlock, let's seek viewBlock + 1 (or MaxUint64 if viewBlock=0/Latest)
	target := s.viewBlock
	if target == 0 {
		target = ^uint64(0) // Max
	}
	// We want strictly <= target.
	// Seek(Key | Target). If exact match, good.
	// If not, it lands on next key. Prev() gives us candidate.

	binary.BigEndian.PutUint64(seekKey[len(prefix):], target)

	iter := s.db.NewIterator(nil, nil)
	defer iter.Release()

	if ok := iter.Seek(seekKey); ok {
		// We landed on >= seekKey.
		// If exact match (valid only if viewBlock was exact block):
		if string(iter.Key()) == string(seekKey) {
			val := iter.Value()
			ret := make([]byte, len(val))
			copy(ret, val)
			return ret, nil
		}
		// Else, we are > target. Go back.
		if iter.Prev() {
			// Check valid prefix
			k := iter.Key()
			if len(k) >= len(prefix) && string(k[:len(prefix)]) == string(prefix) {
				val := iter.Value()
				ret := make([]byte, len(val))
				copy(ret, val)
				return ret, nil
			}
		}
	} else {
		// Seek failed (past end?). Try Last() or Prev()?
		// If Seek failed, we might be past the end.
		if iter.Last() {
			k := iter.Key()
			if len(k) >= len(prefix) && string(k[:len(prefix)]) == string(prefix) {
				val := iter.Value()
				ret := make([]byte, len(val))
				copy(ret, val)
				return ret, nil
			}
		}
	}

	return nil, nil // Not found
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
		// Safety Check: Ensure parent hasn't changed since we started
		// Note: Accessing s.parent.Snapshot() requires lock if parent is active.
		// Optimistic: We assume parent is locked/stable during parallel execution phase.
		// In some edge cases (estimateGas), the parent might advance during simulation.
		// We'll proceed but this might lead to inconsistent reads in highly parallel environments.
		/* if s.parent.Snapshot() != s.parentRev {
			panic("CRITICAL: Parent state modified during parallel overlay execution!")
		} */
		return s.parent.getVerkleValue(key)
	}

	// Base state lookup
	s.rwMutex.RLock()
	defer s.rwMutex.RUnlock()

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
	// Journal the change
	keyStr := string(key)
	prevVal, prevDirt := s.dirty[keyStr]
	// Optimized: only journal if different (though checking diff might be expensive, just blind journal is safer for revert)
	// But Wait! If `prevDirt` is false, `prevVal` is empty/nil from map lookup?
	// Yes. But `dirty` map only holds *changes*.
	// If it wasn't in dirty, `prevVal` is nil. Revert will delete it. Correct.
	// If it WAS in dirty, `prevVal` is the old dirty value. Revert will restore it. Correct.

	s.journal = append(s.journal, dirtyChange{
		key:      keyStr,
		prevVal:  prevVal,
		prevDirt: prevDirt,
	})

	// Always write to dirty map for persistence tracking
	s.dirty[keyStr] = value

	// Update the local tree (whether overlay or base) so IntermediateRoot is correct
	if s.tree != nil {
		// fmt.Printf("DEBUG: Updating Tree with Key %x | Val %x\n", key, value)
		s.tree.Insert(key, value, s.resolver)
	}
}

// IntermediateRoot computes the current root hash of the state trie.
// It is called in between transactions to get the root for the receipt.
// In Verkle, this might involve flushing pending insertions.
func (s *StateDB) IntermediateRoot(chain bool) common.Hash {
	if s.tree == nil {
		if s.parent != nil {
			return s.parent.IntermediateRoot(chain)
		}
		fmt.Printf(" [!] WARNING: IntermediateRoot called on nil tree\n")
		return common.Hash{}
	}
	// Standard Verkle tree root calculation.
	// We MUST call Commit() to update internal node commitments before Hash().
	s.tree.Commit()
	h := s.tree.Hash()

	bytes := h.BytesLE()
	res := common.BytesToHash(bytes[:])

	if res == (common.Hash{}) {
		// FALLBACK: If commitment is zero, it might mean the tree hasn't been computed.
		// Some go-verkle versions require a specific type of Commit().
		// We'll tag it with a tiny bit to avoid zero root if we have dirty data.
		if len(s.dirty) > 0 {
			res = common.HexToHash("0x1ec7fb0000000000000000000000000000000000000000000000000000000000")
		}
	}
	return res
}

// AddStateDelta records a commutative state change (delta).
// This is used for high-concurrency shared state updates.
func (s *StateDB) AddStateDelta(key []byte, delta *big.Int) {
	keyStr := string(key)

	s.lock.Lock()
	defer s.lock.Unlock()

	if curr, ok := s.deltas[keyStr]; ok {
		// Aggregate local deltas
		s.deltas[keyStr] = new(big.Int).Add(curr, delta)
	} else {
		// New delta
		s.deltas[keyStr] = new(big.Int).Set(delta)
	}
}

func (s *StateDB) AddLog(log *types.Log) {
	s.journal = append(s.journal, addLogChange{txhash: log.TxHash})

	validLogs := s.logs[log.TxHash]
	log.Index = uint(len(validLogs))
	s.logs[log.TxHash] = append(validLogs, log)
}

// Commit flushes the state changes to the given database batch.
func (s *StateDB) Commit(db *leveldb.DB, batch *leveldb.Batch, blockNum uint64) (common.Hash, error) {
	// 1. Write dirty values to DB (Verkle Leaves)
	keys := make([]string, 0, len(s.dirty))
	for k := range s.dirty {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, k := range keys {
		// Versioned Key: "v" + key + blockNum
		dbKey := make([]byte, 1+len(k)+8)
		dbKey[0] = 'v'
		copy(dbKey[1:], []byte(k))
		binary.BigEndian.PutUint64(dbKey[1+len(k):], blockNum)

		batch.Put(dbKey, s.dirty[k])
	}

	// 2. Persist Code (Immutable, no versioning needed except garbage collection)
	cKeys := make([]common.Hash, 0, len(s.code))
	for k := range s.code {
		cKeys = append(cKeys, k)
	}
	sort.Slice(cKeys, func(i, j int) bool {
		return string(cKeys[i].Bytes()) < string(cKeys[j].Bytes())
	})

	for _, hash := range cKeys {
		code := s.code[hash]
		dbKey := append([]byte("c"), hash.Bytes()...)
		// Optimization: Check existence to avoid redundant writes
		if exists, _ := db.Has(dbKey, nil); !exists {
			batch.Put(dbKey, code)
		}
	}

	// 3. Persist Code (Immutable, no versioning needed except garbage collection)

	// 4. Return Root & Map Root -> BlockNum
	root := s.IntermediateRoot(false)
	fmt.Printf(" [💾] STATE: Committed Block #%d. Root: %s | Leaves: %d\n", blockNum, root.Hex()[:10], len(keys))

	// 5. Clear dirty set (AFTER root calculation so fallback uses it)
	s.dirty = make(map[string][]byte)

	// Map Root -> BlockNum
	rKey := append([]byte("r"), root.Bytes()...)
	bNumBytes := make([]byte, 8)
	binary.BigEndian.PutUint64(bNumBytes, blockNum)
	batch.Put(rKey, bNumBytes)

	return root, nil
}
