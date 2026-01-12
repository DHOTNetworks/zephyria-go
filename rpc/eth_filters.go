package rpc

import (
	"context"
	"fmt"
	"sort"

	"zephyria/core/rawdb"
	// Using local types for Block/Header if needed, but logs use geth types
	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/rpc"
)

// FilterCriteria represents the options for log filtering.
type FilterCriteria struct {
	BlockHash *common.Hash     `json:"blockHash"`
	FromBlock *rpc.BlockNumber `json:"fromBlock"`
	ToBlock   *rpc.BlockNumber `json:"toBlock"`
	Addresses []common.Address `json:"address"`
	Topics    [][]common.Hash  `json:"topics"`
}

// GetLogs returns logs matching the given criteria.
func (api *PublicEthAPI) GetLogs(ctx context.Context, criteria FilterCriteria) ([]*ethtypes.Log, error) {
	// 1. Determine Block Range
	var begin, end int64

	if criteria.BlockHash != nil {
		// Single block by hash
		block := rawdb.ReadBlock(api.bc.Database(), *criteria.BlockHash)
		if block == nil {
			return nil, nil // Return empty, not error
		}
		number := int64(block.Header.Number.Uint64())
		begin = number
		end = number
	} else {
		// Range by number
		// Resolve FromBlock
		if criteria.FromBlock == nil {
			latest := rpc.LatestBlockNumber
			criteria.FromBlock = &latest
		}
		if *criteria.FromBlock == rpc.LatestBlockNumber || *criteria.FromBlock == rpc.PendingBlockNumber {
			begin = int64(api.bc.CurrentBlock().Header.Number.Uint64())
		} else if *criteria.FromBlock == rpc.EarliestBlockNumber {
			begin = 0
		} else {
			begin = int64(*criteria.FromBlock)
		}

		// Resolve ToBlock
		if criteria.ToBlock == nil {
			latest := rpc.LatestBlockNumber
			criteria.ToBlock = &latest
		}
		if *criteria.ToBlock == rpc.LatestBlockNumber || *criteria.ToBlock == rpc.PendingBlockNumber {
			end = int64(api.bc.CurrentBlock().Header.Number.Uint64())
		} else if *criteria.ToBlock == rpc.EarliestBlockNumber {
			end = 0
		} else {
			end = int64(*criteria.ToBlock)
		}
	}

	// Sanity checks
	headNum := int64(api.bc.CurrentBlock().Header.Number.Uint64())
	if begin > headNum {
		return []*ethtypes.Log{}, nil // Future block
	}
	if end > headNum {
		end = headNum
	}
	if begin > end {
		return []*ethtypes.Log{}, nil
	}

	// Limit range for PoC performance (e.g. max 2000 blocks)
	if end-begin > 2000 {
		return nil, fmt.Errorf("query returned more than 2000 results") // Standard-ish error
	}

	// 2. Determine involved blocks using indices
	blockSet := make(map[uint64]bool)
	useIndex := false

	if len(criteria.Addresses) > 0 {
		useIndex = true
		for _, addr := range criteria.Addresses {
			blocks := rawdb.ReadLogIndices(api.bc.Database(), false, addr.Bytes(), uint64(begin), uint64(end))
			for _, b := range blocks {
				blockSet[b] = true
			}
		}
	}

	if len(criteria.Topics) > 0 && len(criteria.Topics[0]) > 0 {
		for _, sub := range criteria.Topics {
			if len(sub) > 0 {
				tempSet := make(map[uint64]bool)
				for _, topic := range sub {
					blocks := rawdb.ReadLogIndices(api.bc.Database(), true, topic.Bytes(), uint64(begin), uint64(end))
					for _, b := range blocks {
						tempSet[b] = true
					}
				}
				// If we already used indices (e.g. from address or previous topic sublist), intersect.
				// For simplicity here, we just union them and filter later, but intersection is better.
				if useIndex {
					// Intersection (approximate for PoC speed)
					for b := range blockSet {
						if !tempSet[b] {
							delete(blockSet, b)
						}
					}
				} else {
					blockSet = tempSet
					useIndex = true
				}
			}
		}
	}

	// 3. Iterate and Collect
	logs := []*ethtypes.Log{}

	processBlock := func(i uint64) {
		hash := rawdb.ReadCanonicalHash(api.bc.Database(), i)
		if hash == (common.Hash{}) {
			return
		}

		receipts := rawdb.ReadReceipts(api.bc.Database(), hash)
		if receipts == nil {
			return
		}

		cumulativeLogIndex := uint(0)
		for txIndex, receipt := range receipts {
			for _, log := range receipt.Logs {
				if filterLog(log, criteria.Addresses, criteria.Topics) {
					// Add metadata manually
					log.BlockNumber = i
					log.BlockHash = hash

					block := rawdb.ReadBlock(api.bc.Database(), hash)
					if block != nil && txIndex < len(block.Transactions) {
						tx := block.Transactions[txIndex]
						log.TxHash = tx.Hash()
						log.TxIndex = uint(txIndex)
						log.Index = cumulativeLogIndex
					}

					logs = append(logs, log)
				}
				cumulativeLogIndex++
			}
		}
	}

	if useIndex {
		// Only process matching blocks
		sortedBlocks := make([]uint64, 0, len(blockSet))
		for b := range blockSet {
			sortedBlocks = append(sortedBlocks, b)
		}
		sort.Slice(sortedBlocks, func(i, j int) bool { return sortedBlocks[i] < sortedBlocks[j] })
		for _, b := range sortedBlocks {
			processBlock(b)
		}
	} else {
		// Full scan
		for i := begin; i <= end; i++ {
			processBlock(uint64(i))
		}
	}

	return logs, nil
}

func filterLog(log *ethtypes.Log, addresses []common.Address, topics [][]common.Hash) bool {
	// 1. Check Address
	if len(addresses) > 0 {
		found := false
		for _, addr := range addresses {
			if log.Address == addr {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}

	// 2. Check Topics
	// topics is [ [A, B], [C], nil, [D] ]
	// log must match ONE from each non-empty position
	for i, sub := range topics {
		if i >= len(log.Topics) {
			return false // Log doesn't have enough topics
		}
		if len(sub) == 0 {
			continue // Wildcard for this position
		}

		match := false
		for _, topic := range sub {
			if log.Topics[i] == topic {
				match = true
				break
			}
		}
		if !match {
			return false
		}
	}
	return true
}
