package rpc

import (
	"context"
	"math/big"

	"zephyria/core/rawdb"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
)

// GetTransactionByHash returns the transaction for the given hash.
func (api *PublicEthAPI) GetTransactionByHash(ctx context.Context, hash common.Hash) (map[string]interface{}, error) {
	// 1. Look up location
	entry := rawdb.ReadTxLookupEntry(api.bc.Database(), hash)
	if entry == nil {
		return nil, nil // Not found
	}

	// 2. Load Block
	block := rawdb.ReadBlock(api.bc.Database(), entry.BlockHash)
	if block == nil {
		return nil, nil
	}

	// 3. Extract Tx
	if entry.TxIndex >= uint64(len(block.Transactions)) {
		return nil, nil
	}
	tx := block.Transactions[entry.TxIndex]

	// 4. Construct Response with Metadata
	chainCfg := api.bc.Config().ChainConfig()
	signer := ethtypes.LatestSigner(chainCfg)
	from, _ := ethtypes.Sender(signer, tx)

	res := map[string]interface{}{
		"hash":             tx.Hash(),
		"nonce":            hexutil.Uint64(tx.Nonce()),
		"blockHash":        entry.BlockHash,
		"blockNumber":      hexutil.Uint64(entry.BlockIndex),
		"transactionIndex": hexutil.Uint64(entry.TxIndex),
		"from":             from,
		"to":               tx.To(),
		"value":            (*hexutil.Big)(tx.Value()),
		"gas":              hexutil.Uint64(tx.Gas()),
		"gasPrice":         (*hexutil.Big)(tx.GasPrice()),
		"input":            hexutil.Bytes(tx.Data()),
		"v":                hexutil.Uint64(0), // Simplified V/R/S handling if accessors awkward
		"r":                hexutil.Uint64(0),
		"s":                hexutil.Uint64(0),
		"type":             hexutil.Uint64(tx.Type()),
		"chainId":          (*hexutil.Big)(tx.ChainId()),
	}
	// Add V, R, S if accessible - ethtypes.Transaction accessors needed
	v, r, s := tx.RawSignatureValues()
	res["v"] = (*hexutil.Big)(v)
	res["r"] = (*hexutil.Big)(r)
	res["s"] = (*hexutil.Big)(s)

	return res, nil
}

// GetTransactionReceipt returns the receipt for the given transaction hash.
func (api *PublicEthAPI) GetTransactionReceipt(ctx context.Context, hash common.Hash) (map[string]interface{}, error) {
	// 1. Look up location
	entry := rawdb.ReadTxLookupEntry(api.bc.Database(), hash)
	if entry == nil {
		return nil, nil
	}

	// 2. Load Block
	block := rawdb.ReadBlock(api.bc.Database(), entry.BlockHash)
	if block == nil {
		return nil, nil
	}

	// 3. Load Receipts
	receipts := rawdb.ReadReceipts(api.bc.Database(), entry.BlockHash)
	if receipts == nil {
		return nil, nil
	}
	if entry.TxIndex >= uint64(len(receipts)) {
		return nil, nil
	}
	receipt := receipts[entry.TxIndex]

	// 4. Format as map
	tx := block.Transactions[entry.TxIndex]
	chainCfg := api.bc.Config().ChainConfig()
	signer := ethtypes.LatestSigner(chainCfg)
	from, _ := ethtypes.Sender(signer, tx)

	// logs
	logs := receipt.Logs
	if logs == nil {
		logs = []*ethtypes.Log{}
	}
	// Hydrate logs with metadata for the receipt view
	for i, log := range logs {
		log.BlockNumber = entry.BlockIndex
		log.BlockHash = entry.BlockHash
		log.TxHash = hash
		log.TxIndex = uint(entry.TxIndex)
		log.Index = uint(i) // Local index
		log.Removed = false
	}

	// Contract Address
	var contractAddr interface{} = nil
	if (receipt.ContractAddress != common.Address{}) {
		contractAddr = receipt.ContractAddress
	}

	// Effective Gas Price
	effectiveGasPrice := tx.GasPrice()
	if block.Header.BaseFee != nil {
		priority := new(big.Int).Add(block.Header.BaseFee, tx.GasTipCap())
		if priority.Cmp(effectiveGasPrice) < 0 {
			effectiveGasPrice = priority
		}
	}

	res := map[string]interface{}{
		"transactionHash":   hash,
		"transactionIndex":  hexutil.Uint64(entry.TxIndex),
		"blockHash":         entry.BlockHash,
		"blockNumber":       hexutil.Uint64(entry.BlockIndex),
		"from":              from,
		"to":                tx.To(),
		"cumulativeGasUsed": hexutil.Uint64(receipt.CumulativeGasUsed),
		"gasUsed":           hexutil.Uint64(receipt.GasUsed),
		"effectiveGasPrice": (*hexutil.Big)(effectiveGasPrice),
		"contractAddress":   contractAddr,
		"logs":              logs,
		"logsBloom":         receipt.Bloom,
		"status":            hexutil.Uint64(receipt.Status),
		"type":              hexutil.Uint64(tx.Type()),
	}
	return res, nil
}
