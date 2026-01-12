package state

import (
	"encoding/binary"

	"github.com/syndtr/goleveldb/leveldb"
	"github.com/syndtr/goleveldb/leveldb/util"
)

// Prune removes state versions older than thresholdBlock.
func (s *StateDB) Prune(thresholdBlock uint64) int {
	if s.db == nil {
		return 0
	}

	// Iterate all "v" keys
	iter := s.db.NewIterator(util.BytesPrefix([]byte("v")), nil)
	defer iter.Release()

	batch := new(leveldb.Batch)
	deleted := 0

	for iter.Next() {
		k := iter.Key() // v + key + blockNum
		if len(k) < 9 {
			continue
		}

		// Extract BlockNum (Last 8 bytes)
		bNumBytes := k[len(k)-8:]
		bNum := binary.BigEndian.Uint64(bNumBytes)

		if bNum < thresholdBlock {
			batch.Delete(k)
			deleted++
		}

		if batch.Len() > 1000 {
			s.db.Write(batch, nil)
			batch.Reset()
		}
	}
	if batch.Len() > 0 {
		s.db.Write(batch, nil)
	}
	// fmt.Printf("Pruned %d state entries older than block %d\n", deleted, thresholdBlock)
	return deleted
}
