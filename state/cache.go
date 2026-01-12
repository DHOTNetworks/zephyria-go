package state

import (
	"encoding/binary"

	"github.com/syndtr/goleveldb/leveldb/util"
)

var cacheKey = []byte("StateTreeKeyCache")

func (s *StateDB) loadTreeFromCache() {
	// 1. Get Cache
	data, err := s.db.Get(cacheKey, nil)
	if err != nil {
		// Fallback: Full Scan (expensive)
		// fmt.Println("No state cache, scanning DB...")
		iter := s.db.NewIterator(util.BytesPrefix([]byte("v")), nil)
		uniqueKeys := make(map[string]bool)
		for iter.Next() {
			k := iter.Key() // v + key + blockNum
			if len(k) < 9 {
				continue
			}
			// Extract plain key
			plainKey := k[1 : len(k)-8]
			uniqueKeys[string(plainKey)] = true
		}
		iter.Release()

		for k := range uniqueKeys {
			if val, err := s.resolver([]byte(k)); err == nil && len(val) > 0 {
				s.tree.Insert([]byte(k), val, s.resolver)
			}
		}
		return
	}

	// 2. Load keys from cache
	// Format: Length(4 bytes) | Key...
	buf := data
	count := 0
	for len(buf) > 4 {
		keyLen := binary.BigEndian.Uint32(buf[:4])
		buf = buf[4:]
		if len(buf) < int(keyLen) {
			break
		}
		key := buf[:keyLen]
		buf = buf[keyLen:]

		if val, err := s.resolver(key); err == nil && len(val) > 0 {
			s.tree.Insert(key, val, s.resolver)
		}
		count++
	}
	// fmt.Printf("Loaded %d keys from state cache.\n", count)
}

// SaveTreeCache saves the current active keys to the cache.
// Call this periodically (e.g. on shutdown or specific interval).
func (s *StateDB) SaveTreeCache() error {
	if s.db == nil {
		return nil
	}

	// We cannot iterate the implementation-hidden tree easily.
	// But since we just rebuilt it or modified it,
	// we can iterate the DB "v" prefix again to find all unique keys?
	// That is slow but correct for "Save".
	// Faster: Maintain a separate "ActiveKeys" index?
	// For PoC: Just verify we CAN save.
	// Iterating DB on shutdown is acceptable.

	iter := s.db.NewIterator(util.BytesPrefix([]byte("v")), nil)
	defer iter.Release()

	uniqueKeys := make(map[string]bool)
	for iter.Next() {
		k := iter.Key()
		if len(k) < 9 {
			continue
		}
		plainKey := k[1 : len(k)-8]
		uniqueKeys[string(plainKey)] = true
	}

	// Encode
	var buf []byte
	for k := range uniqueKeys {
		kb := []byte(k)
		lenBytes := make([]byte, 4)
		binary.BigEndian.PutUint32(lenBytes, uint32(len(kb)))
		buf = append(buf, lenBytes...)
		buf = append(buf, kb...)
	}

	return s.db.Put(cacheKey, buf, nil)
}
