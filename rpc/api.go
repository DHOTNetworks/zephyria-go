package rpc

import (
	"context"

	"zephyria/core"
	"zephyria/core/rawdb"
	"zephyria/state"
	ztypes "zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/rlp"
	"github.com/ethereum/go-ethereum/rpc"
	"github.com/ethereum/go-ethereum/trie"
)

// PublicEthAPI provides the eth_ 1.0 API.
type PublicEthAPI struct {
	bc      *core.Blockchain
	statedb *state.StateDB
	// consensus engine or tx pool interaction needed for SendRawTx
	txCh chan *types.Transaction // simplified mechanism to send txs to main loop
}

func NewPublicEthAPI(bc *core.Blockchain, s *state.StateDB, txCh chan *types.Transaction) *PublicEthAPI {
	return &PublicEthAPI{
		bc:      bc,
		statedb: s,
		txCh:    txCh,
	}
}

// BlockNumber returns the current block number.
func (api *PublicEthAPI) BlockNumber() *hexutil.Big {
	header := api.bc.CurrentBlock().Header
	return (*hexutil.Big)(header.Number)
}

// GetBalance is the standard alias for BalanceAt (handled by geth rpc wrapper usually, but explicit here).
// Standard: eth_getBalance(address, block)
func (api *PublicEthAPI) GetBalance(ctx context.Context, address common.Address, blockNrOrHash rpc.BlockNumberOrHash) (*hexutil.Big, error) {
	// For PoC: assume latest state always (ignoring blockNrOrHash for now)
	// Ideally we load state trie from block hash.
	// If blockNrOrHash is set, we should try to load it.
	// Since we don't have State History easily accessible without `state.New(root)`, let's attempt it.

	var stateDB *state.StateDB = api.statedb

	// Attempt historical lookup if requested (Basic impl)
	if blockNrOrHash.BlockNumber != nil && *blockNrOrHash.BlockNumber != rpc.LatestBlockNumber {
		// Load block, get root, make new state?
		// Only if we have trie persistence. Verkle is implemented.
		// Let's stick to Latest for PoC safety unless critical.
	}

	bal := stateDB.GetBalance(address)
	return (*hexutil.Big)(bal.ToBig()), nil
}

// ChainId standard RPC
func (api *PublicEthAPI) ChainId() *hexutil.Big {
	config := api.bc.Config()
	return (*hexutil.Big)(config.ChainID)
}

// NetVersion standard RPC
func (api *PublicEthAPI) NetVersion() string {
	config := api.bc.Config()
	return config.ChainID.String()
}

// GetTransactionCount returns the number of transactions sent from an address.
func (api *PublicEthAPI) GetTransactionCount(ctx context.Context, address common.Address, blockNrOrHash rpc.BlockNumberOrHash) (*hexutil.Uint64, error) {
	nonce := api.statedb.GetNonce(address)
	return (*hexutil.Uint64)(&nonce), nil
}

// SendRawTransaction submits a signed transaction to the pool/consensus.
func (api *PublicEthAPI) SendRawTransaction(ctx context.Context, data hexutil.Bytes) (common.Hash, error) {
	tx := new(types.Transaction)
	if err := rlp.DecodeBytes(data, tx); err != nil {
		return common.Hash{}, err
	}

	// Send to main loop
	go func() {
		api.txCh <- tx
	}()

	return tx.Hash(), nil
}

// GetBlockByNumber returns the requested block.
func (api *PublicEthAPI) GetBlockByNumber(ctx context.Context, blockNr rpc.BlockNumber, fullTx bool) (map[string]interface{}, error) {
	var block *ztypes.Block
	if blockNr == rpc.LatestBlockNumber {
		block = api.bc.CurrentBlock()
	} else if blockNr == rpc.PendingBlockNumber {
		return nil, nil // Pending not supported yet
	} else {
		num := uint64(blockNr)
		hash := rawdb.ReadCanonicalHash(api.bc.Database(), num)
		if (hash != common.Hash{}) {
			block = rawdb.ReadBlock(api.bc.Database(), hash)
		}
	}

	if block == nil {
		return nil, nil
	}

	// Compute transactions root
	txs := block.Transactions
	txRoot := types.DeriveSha(types.Transactions(txs), trie.NewStackTrie(nil))

	res := map[string]interface{}{
		"number":           hexutil.Uint64(block.Header.Number.Uint64()),
		"hash":             block.Hash(),
		"parentHash":       block.Header.ParentHash,
		"nonce":            hexutil.Bytes(make([]byte, 8)),
		"sha3Uncles":       types.EmptyUncleHash,
		"logsBloom":        types.Bloom{},
		"transactionsRoot": txRoot,
		"stateRoot":        block.Header.VerkleRoot,
		"receiptsRoot":     types.EmptyRootHash,
		"miner":            block.Header.Coinbase,
		"difficulty":       (*hexutil.Big)(block.Header.Difficulty),
		"totalDifficulty":  (*hexutil.Big)(block.Header.Difficulty),
		"extraData":        hexutil.Bytes(block.Header.ExtraData),
		"size":             hexutil.Uint64(1000), // Approximate
		"gasLimit":         hexutil.Uint64(block.Header.GasLimit),
		"gasUsed":          hexutil.Uint64(block.Header.GasUsed),
		"timestamp":        hexutil.Uint64(block.Header.Time),
		"uncles":           []common.Hash{},
		"mixHash":          common.Hash{},
	}

	if block.Header.BaseFee != nil {
		res["baseFeePerGas"] = (*hexutil.Big)(block.Header.BaseFee)
	}

	if fullTx {
		txs := make([]*types.Transaction, len(block.Transactions))
		copy(txs, block.Transactions)
		res["transactions"] = txs
	} else {
		hashes := make([]common.Hash, len(block.Transactions))
		for i, tx := range block.Transactions {
			hashes[i] = tx.Hash()
		}
		res["transactions"] = hashes
	}

	return res, nil
}

// GetBlockByHash returns the requested block.
func (api *PublicEthAPI) GetBlockByHash(ctx context.Context, hash common.Hash, fullTx bool) (map[string]interface{}, error) {
	block := rawdb.ReadBlock(api.bc.Database(), hash)
	if block == nil {
		return nil, nil
	}
	// Reuse specific formatting logic? For now replicate or refactor.
	// Simplifying: Just call GetBlockByNumber with number logic? No, we have block.
	// Just copy paste formatting for speed.

	txs := block.Transactions
	txRoot := types.DeriveSha(types.Transactions(txs), trie.NewStackTrie(nil))

	res := map[string]interface{}{
		"number":           hexutil.Uint64(block.Header.Number.Uint64()),
		"hash":             block.Hash(),
		"parentHash":       block.Header.ParentHash,
		"nonce":            hexutil.Bytes(make([]byte, 8)),
		"sha3Uncles":       types.EmptyUncleHash,
		"logsBloom":        types.Bloom{},
		"transactionsRoot": txRoot,
		"stateRoot":        block.Header.VerkleRoot,
		"receiptsRoot":     types.EmptyRootHash,
		"miner":            block.Header.Coinbase,
		"difficulty":       (*hexutil.Big)(block.Header.Difficulty),
		"totalDifficulty":  (*hexutil.Big)(block.Header.Difficulty),
		"extraData":        hexutil.Bytes(block.Header.ExtraData),
		"size":             hexutil.Uint64(1000),
		"gasLimit":         hexutil.Uint64(block.Header.GasLimit),
		"gasUsed":          hexutil.Uint64(block.Header.GasUsed),
		"timestamp":        hexutil.Uint64(block.Header.Time),
		"uncles":           []common.Hash{},
	}
	if block.Header.BaseFee != nil {
		res["baseFeePerGas"] = (*hexutil.Big)(block.Header.BaseFee)
	}

	if fullTx {
		txs := make([]*types.Transaction, len(block.Transactions))
		copy(txs, block.Transactions)
		res["transactions"] = txs
	} else {
		hashes := make([]common.Hash, len(block.Transactions))
		for i, tx := range block.Transactions {
			hashes[i] = tx.Hash()
		}
		res["transactions"] = hashes
	}
	return res, nil
}

// GetTransactionByHash returns the transaction for the given hash.
func (api *PublicEthAPI) GetTransactionByHash(ctx context.Context, hash common.Hash) (*types.Transaction, error) {
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
	return block.Transactions[entry.TxIndex], nil
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
	if receipts == nil || entry.TxIndex >= uint64(len(receipts)) {
		return nil, nil
	}
	receipt := receipts[entry.TxIndex]

	// 4. Format as map
	tx := block.Transactions[entry.TxIndex]
	chainCfg := api.bc.Config().ChainConfig()
	signer := types.LatestSigner(chainCfg)
	from, _ := types.Sender(signer, tx)

	res := map[string]interface{}{
		"transactionHash":   hash,
		"transactionIndex":  hexutil.Uint64(entry.TxIndex),
		"blockHash":         entry.BlockHash,
		"blockNumber":       hexutil.Uint64(entry.BlockIndex),
		"from":              from,
		"to":                tx.To(),
		"cumulativeGasUsed": hexutil.Uint64(receipt.CumulativeGasUsed),
		"gasUsed":           hexutil.Uint64(receipt.GasUsed),
		"contractAddress":   receipt.ContractAddress,
		"logs":              receipt.Logs,
		"logsBloom":         receipt.Bloom,
		"status":            hexutil.Uint64(receipt.Status),
	}
	return res, nil
}
