package rawdb

import (
	"encoding/binary"
	"encoding/json"
	"strings"

	"zephyria/types"

	"fmt" // Added for debugging

	"github.com/ethereum/go-ethereum/common"
	"github.com/syndtr/goleveldb/leveldb"
)

// Prefixes
var (
	blockHeaderPrefix   = []byte("h")          // h + num + hash -> header
	blockBodyPrefix     = []byte("b")          // b + num + hash -> body
	blockReceiptsPrefix = []byte("r")          // r + num + hash -> receipts
	txLookupPrefix      = []byte("l")          // l + txHash -> {blockHash, blockNum, txIndex}
	headHeaderPrefix    = []byte("HeadHeader") // -> hash
	headBlockPrefix     = []byte("HeadBlock")  // -> hash
	logAddrPrefix       = []byte("LA")         // LA + addr + blockNum -> blockHash
	logTopicPrefix      = []byte("LT")         // LT + topic + blockNum -> blockHash
)

// WriteBlock writes a block to the database.
func WriteBlock(db *leveldb.DB, block *types.Block) error {
	// Serialize
	data, err := json.Marshal(block)
	if err != nil {
		return err
	}

	// Key: b + hash
	key := append(blockBodyPrefix, block.Hash().Bytes()...)
	return db.Put(key, data, nil)
}

// ReadBlock reads a block from the database.
func ReadBlock(db *leveldb.DB, hash common.Hash) *types.Block {
	key := append(blockBodyPrefix, hash.Bytes()...)
	data, err := db.Get(key, nil)
	if err != nil {
		return nil
	}

	var block types.Block
	if err := json.Unmarshal(data, &block); err != nil {
		return nil
	}
	return &block
}

// WriteReceipts stores the receipts for a block.
func WriteReceipts(db *leveldb.DB, block *types.Block, receipts []*types.Receipt) error {
	data, err := json.Marshal(receipts)
	if err != nil {
		return err
	}
	// Key: r + hash (simplified, Geth uses num+hash)
	key := append(blockReceiptsPrefix, block.Hash().Bytes()...)
	return db.Put(key, data, nil)
}

// ReadReceipts retrieves receipts for a block.
func ReadReceipts(db *leveldb.DB, hash common.Hash) []*types.Receipt {
	key := append(blockReceiptsPrefix, hash.Bytes()...)
	data, err := db.Get(key, nil)
	if err != nil {
		return nil
	}
	var receipts []*types.Receipt
	if err := json.Unmarshal(data, &receipts); err != nil {
		return nil
	}
	return receipts
}

// TxLookupEntry is the stored index for a transaction.
type TxLookupEntry struct {
	BlockHash  common.Hash `json:"blockHash"`
	BlockIndex uint64      `json:"blockIndex"` // Index of block in chain (number)
	TxIndex    uint64      `json:"txIndex"`    // Index of tx in block
}

// WriteTxLookupEntries stores indices for all transactions in a block.
func WriteTxLookupEntries(db *leveldb.DB, block *types.Block) error {
	for i, tx := range block.Transactions {
		// Log
		fmt.Printf("DB: Indexing Tx %s at Block %d Index %d\n", tx.Hash().Hex(), block.Header.Number.Uint64(), i)

		entry := TxLookupEntry{
			BlockHash:  block.Hash(),
			BlockIndex: block.Header.Number.Uint64(),
			TxIndex:    uint64(i),
		}
		data, err := json.Marshal(entry)
		if err != nil {
			return err
		}
		key := append(txLookupPrefix, tx.Hash().Bytes()...)
		if err := db.Put(key, data, nil); err != nil {
			return err
		}
	}
	return nil
}

// ReadTxLookupEntry returns location of a tx.
func ReadTxLookupEntry(db *leveldb.DB, txHash common.Hash) *TxLookupEntry {
	key := append(txLookupPrefix, txHash.Bytes()...)
	data, err := db.Get(key, nil)
	if err != nil {
		return nil
	}
	var entry TxLookupEntry
	if err := json.Unmarshal(data, &entry); err != nil {
		return nil
	}
	return &entry
}

// ReadLogIndices searches the index for blocks containing an address or topic.
func ReadLogIndices(db *leveldb.DB, isTopic bool, key []byte, begin, end uint64) []uint64 {
	prefix := logAddrPrefix
	if isTopic {
		prefix = logTopicPrefix
	}

	start := make([]byte, len(prefix)+len(key)+8)
	copy(start, prefix)
	copy(start[len(prefix):], key)
	binary.BigEndian.PutUint64(start[len(prefix)+len(key):], begin)

	iter := db.NewIterator(nil, nil)
	defer iter.Release()

	var blocks []uint64
	// Search target: Prefix + Key
	targetPrefix := append(prefix, key...)

	if ok := iter.Seek(start); ok {
		for {
			k := iter.Key()
			if !strings.HasPrefix(string(k), string(targetPrefix)) {
				break
			}
			num := binary.BigEndian.Uint64(k[len(k)-8:])
			if num > end {
				break
			}
			blocks = append(blocks, num)
			if !iter.Next() {
				break
			}
		}
	}
	return blocks
}

// WriteHeadBlockHash stores the head block hash.
func WriteHeadBlockHash(db *leveldb.DB, hash common.Hash) error {
	return db.Put(headBlockPrefix, hash.Bytes(), nil)
}

// ReadHeadBlockHash retrieves the head block hash.
func ReadHeadBlockHash(db *leveldb.DB) common.Hash {
	data, err := db.Get(headBlockPrefix, nil)
	if err != nil {
		return common.Hash{}
	}
	return common.BytesToHash(data)
}

// WriteCanonicalHash stores the canonical hash for a block number.
func WriteCanonicalHash(db *leveldb.DB, number uint64, hash common.Hash) error {
	var numBytes [8]byte
	binary.BigEndian.PutUint64(numBytes[:], number)
	key := append([]byte("H"), numBytes[:]...)
	return db.Put(key, hash.Bytes(), nil)
}

// ReadCanonicalHash retrieves the canonical hash for a block number.
// ReadCanonicalHash retrieves the canonical hash for a block number.
func ReadCanonicalHash(db *leveldb.DB, number uint64) common.Hash {
	var numBytes [8]byte
	binary.BigEndian.PutUint64(numBytes[:], number)
	key := append([]byte("H"), numBytes[:]...)
	data, err := db.Get(key, nil)
	if err != nil {
		return common.Hash{}
	}
	return common.BytesToHash(data)
}

// IndexLogs creates indices for address and topics for fast retrieval.
func IndexLogs(db *leveldb.DB, blockHash common.Hash, blockNum uint64, receipts []*types.Receipt) error {
	batch := new(leveldb.Batch)

	for _, receipt := range receipts {
		uniqueAddrs := make(map[common.Address]struct{})
		uniqueTopics := make(map[common.Hash]struct{})

		for _, log := range receipt.Logs {
			uniqueAddrs[log.Address] = struct{}{}
			for _, topic := range log.Topics {
				uniqueTopics[topic] = struct{}{}
			}
		}

		// Write Address Indices
		for addr := range uniqueAddrs {
			key := make([]byte, len(logAddrPrefix)+20+8)
			copy(key, logAddrPrefix)
			copy(key[len(logAddrPrefix):], addr.Bytes())
			binary.BigEndian.PutUint64(key[len(logAddrPrefix)+20:], blockNum)
			batch.Put(key, blockHash.Bytes())
		}

		// Write Topic Indices
		for topic := range uniqueTopics {
			key := make([]byte, len(logTopicPrefix)+32+8)
			copy(key, logTopicPrefix)
			copy(key[len(logTopicPrefix):], topic.Bytes())
			binary.BigEndian.PutUint64(key[len(logTopicPrefix)+32:], blockNum)
			batch.Put(key, blockHash.Bytes())
		}
	}

	return db.Write(batch, nil)
}
