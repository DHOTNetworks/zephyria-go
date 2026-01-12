package rpc

import (
	"context"
	"fmt"
	"math/big"
	"os"

	"zephyria/core"
	"zephyria/core/rawdb"
	"zephyria/state"
	ztypes "zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/rpc"
	"github.com/ethereum/go-ethereum/trie"
)

// PublicEthAPI provides the eth_ 1.0 API.
type PublicEthAPI struct {
	bc       *core.Blockchain
	statedb  *state.StateDB
	txPool   *core.TxPool
	executor *core.Executor
}

func NewPublicEthAPI(bc *core.Blockchain, s *state.StateDB, pool *core.TxPool, executor *core.Executor) *PublicEthAPI {
	return &PublicEthAPI{
		bc:       bc,
		statedb:  s,
		txPool:   pool,
		executor: executor,
	}
}

// BlockNumber returns the current block number.
func (api *PublicEthAPI) BlockNumber() (*hexutil.Big, error) {
	fmt.Fprintf(os.Stderr, "[RPC] eth_blockNumber called\n")
	header := api.bc.CurrentBlock().Header
	return (*hexutil.Big)(header.Number), nil
}

// GetBalance is the standard alias for BalanceAt (handled by geth rpc wrapper usually, but explicit here).
// Standard: eth_getBalance(address, block)
func (api *PublicEthAPI) GetBalance(ctx context.Context, address common.Address, blockNrOrHash *rpc.BlockNumberOrHash) (*hexutil.Big, error) {
	fmt.Fprintf(os.Stderr, "[RPC] eth_getBalance called for %s\n", address.Hex())
	// Resolve Header
	header, err := api.headerByRpcBlock(ctx, blockNrOrHash)
	if err != nil {
		return nil, err
	}
	// Get State at that block
	state, err := api.bc.StateAt(header.VerkleRoot)
	if err != nil {
		return nil, err
	}
	bal := state.GetBalance(address)
	return (*hexutil.Big)(bal.ToBig()), nil
}

// ChainId standard RPC
func (api *PublicEthAPI) ChainId() (*hexutil.Big, error) {
	fmt.Fprintf(os.Stderr, "[RPC] eth_chainId called\n")
	config := api.bc.Config()
	return (*hexutil.Big)(config.ChainID), nil
}

// NetVersion standard RPC
func (api *PublicEthAPI) NetVersion() string {
	config := api.bc.Config()
	return config.ChainID.String()
}

// GetTransactionCount returns the number of transactions sent from an address.
func (api *PublicEthAPI) GetTransactionCount(ctx context.Context, address common.Address, blockNrOrHash *rpc.BlockNumberOrHash) (*hexutil.Uint64, error) {
	fmt.Fprintf(os.Stderr, "[RPC] eth_getTransactionCount called for %s\n", address.Hex())
	// Resolve Header (Default to Latest/Pending)
	header, err := api.headerByRpcBlock(ctx, blockNrOrHash)
	if err != nil {
		return nil, err
	}
	state, err := api.bc.StateAt(header.VerkleRoot)
	if err != nil {
		return nil, err
	}
	nonce := state.GetNonce(address)
	return (*hexutil.Uint64)(&nonce), nil
}

// SendRawTransaction submits a signed transaction to the pool/consensus.
func (api *PublicEthAPI) SendRawTransaction(ctx context.Context, data hexutil.Bytes) (common.Hash, error) {
	fmt.Fprintf(os.Stderr, "[RPC] eth_sendRawTransaction called (size: %d)\n", len(data))
	tx := new(types.Transaction)
	// Handle hex-encoded strings passed as raw bytes
	if len(data) > 2 && data[0] == '0' && data[1] == 'x' {
		decoded, err := hexutil.Decode(string(data))
		if err == nil {
			data = decoded
		}
	}

	if err := tx.UnmarshalBinary(data); err != nil {
		return common.Hash{}, fmt.Errorf("decoding failed: %v", err)
	}

	// 1. Validate ChainID
	chainID := api.bc.Config().ChainID
	if tx.ChainId() != nil && tx.ChainId().Sign() > 0 {
		if tx.ChainId().Cmp(chainID) != 0 {
			return common.Hash{}, fmt.Errorf("invalid chain id: have %v, want %v", tx.ChainId(), chainID)
		}
	}

	// 2. Recover Sender (Validate Signature)
	signer := types.LatestSigner(api.bc.Config().ChainConfig())
	from, err := types.Sender(signer, tx)
	if err != nil {
		return common.Hash{}, fmt.Errorf("invalid transaction signature: %v", err)
	}

	// 3. Size Limit Check (Zephyria PoC: 512KB)
	if tx.Size() > 512*1024 {
		return common.Hash{}, fmt.Errorf("oversized transaction: %d > %d", tx.Size(), 512*1024)
	}

	// 4. State Validation (Nonce & Balance)
	// We must check against CURRENT state to reject invalid txs immediately.
	currentBlock := api.bc.CurrentBlock()
	if currentBlock == nil {
		return common.Hash{}, fmt.Errorf("node not ready: current block is nil")
	}
	header := currentBlock.Header

	state, err := api.bc.StateAt(header.VerkleRoot)
	if err != nil {
		return common.Hash{}, fmt.Errorf("failed to load state for validation: %v", err)
	}

	// Nonce Check
	confirmedNonce := state.GetNonce(from)
	if tx.Nonce() < confirmedNonce {
		return common.Hash{}, fmt.Errorf("nonce too low: address %s, tx: %d state: %d", from.Hex(), tx.Nonce(), confirmedNonce)
	}
	// Note: We accept gaps (tx.Nonce() > confirmedNonce) for pool buffering,
	// but for this simple node we might want to warn or accept.
	// Standard Geth accepts gaps. We'll accept gaps too.

	// Balance Check
	// Cost = Value + Gas * GasPrice
	balance := state.GetBalance(from)
	cost := new(big.Int).Mul(new(big.Int).SetUint64(tx.Gas()), tx.GasPrice())
	cost.Add(cost, tx.Value())

	balanceBig := balance.ToBig()
	if balanceBig.Cmp(cost) < 0 {
		return common.Hash{}, fmt.Errorf("insufficient funds for gas * price + value: address %s have %v want %v", from.Hex(), balanceBig, cost)
	}

	// Send to pool
	if api.txPool != nil {
		if _, err := api.txPool.Add(tx); err != nil {
			return common.Hash{}, err
		}
	}

	return tx.Hash(), nil
}

// GetBlockByNumber returns the requested block.
func (api *PublicEthAPI) GetBlockByNumber(ctx context.Context, blockNr rpc.BlockNumber, fullTx bool) (map[string]interface{}, error) {
	fmt.Fprintf(os.Stderr, "[RPC] eth_getBlockByNumber called (%v, %v)\n", blockNr, fullTx)
	if err := api.validateBlockNumber(blockNr); err != nil {
		return nil, err
	}

	var block *ztypes.Block
	if blockNr == rpc.LatestBlockNumber || blockNr == rpc.PendingBlockNumber {
		block = api.bc.CurrentBlock()
	} else if blockNr == rpc.EarliestBlockNumber {
		block = api.bc.GenesisBlock()
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
		"difficulty":       hexutil.Uint64(0),
		"totalDifficulty":  hexutil.Uint64(0),
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
		"difficulty":       hexutil.Uint64(0),
		"totalDifficulty":  hexutil.Uint64(0),
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

// Methods moved to eth_tx.go

// ---------------------------------------------------------------------
// Metamask Support Methods (Standard ETH RPC)
// ---------------------------------------------------------------------

// GasPrice returns a suggested gas price.
func (api *PublicEthAPI) GasPrice(ctx context.Context) (*hexutil.Big, error) {
	fmt.Fprintf(os.Stderr, "[RPC] eth_gasPrice called\n")
	// Suggest a price: BaseFee + Tip
	// For PoC, let's query the latest block base fee.
	head := api.bc.CurrentBlock().Header
	if head.BaseFee != nil {
		// return BaseFee + 2 Gwei tip (matching MaxPriorityFee)
		tip := big.NewInt(2000000000)
		price := new(big.Int).Add(head.BaseFee, tip)
		return (*hexutil.Big)(price), nil
	}
	// Fallback 20 Gwei
	return (*hexutil.Big)(big.NewInt(20000000000)), nil
}

// MaxPriorityFeePerGas (EIP-1559)
func (api *PublicEthAPI) MaxPriorityFeePerGas(ctx context.Context) (*hexutil.Big, error) {
	// Suggest 2 Gwei tip
	return (*hexutil.Big)(big.NewInt(2000000000)), nil
}

// FeeHistory (EIP-1559) - Provides historical gas information for MetaMask
func (api *PublicEthAPI) FeeHistory(ctx context.Context, blockCount rpc.BlockNumber, lastBlock rpc.BlockNumber, rewardPercentiles []float64) (map[string]interface{}, error) {
	if err := api.validateBlockNumber(lastBlock); err != nil {
		return nil, err
	}

	// Determine end block
	var end uint64
	if lastBlock == rpc.LatestBlockNumber || lastBlock == rpc.PendingBlockNumber {
		end = api.bc.CurrentBlock().Header.Number.Uint64()
	} else {
		end = uint64(lastBlock)
	}

	count := uint64(blockCount)
	if blockCount < 1 || blockCount > 1024 {
		return nil, fmt.Errorf("blockCount must be between 1 and 1024")
	}

	for _, p := range rewardPercentiles {
		if p < 0 || p > 100 {
			return nil, fmt.Errorf("reward percentile must be between 0 and 100")
		}
	}
	start := uint64(0)
	if end > count {
		start = end - count
	}

	oldestBlock := (*hexutil.Big)(new(big.Int).SetUint64(start))
	baseFees := make([]*hexutil.Big, 0)
	gasUsedRatios := make([]float64, 0)
	rewards := make([][]*hexutil.Big, 0)

	for i := start; i <= end; i++ {
		block := api.bc.GetBlockByNumber(i)
		if block == nil {
			continue
		}
		baseFees = append(baseFees, (*hexutil.Big)(block.Header.BaseFee))
		gasUsedRatios = append(gasUsedRatios, float64(block.Header.GasUsed)/float64(block.Header.GasLimit))

		// Rewards (Tips) - For now return a fixed 2 Gwei suggestion across percentiles
		row := make([]*hexutil.Big, len(rewardPercentiles))
		for j := range rewardPercentiles {
			row[j] = (*hexutil.Big)(big.NewInt(2000000000)) // 2 Gwei Fixed
		}
		rewards = append(rewards, row)
	}

	// Add one extra baseFee for the "next" block as per standard
	nextBaseFee := core.CalcBaseFee(api.bc.Config().ChainConfig(), api.bc.CurrentBlock().Header)
	baseFees = append(baseFees, (*hexutil.Big)(nextBaseFee))

	return map[string]interface{}{
		"oldestBlock":   oldestBlock,
		"baseFeePerGas": baseFees,
		"gasUsedRatio":  gasUsedRatios,
		"reward":        rewards,
	}, nil
}

// EstimateGas estimates gas usage for the transaction.
func (api *PublicEthAPI) EstimateGas(ctx context.Context, args CallArgs, blockNrOrHash *rpc.BlockNumberOrHash) (*hexutil.Uint64, error) {
	fmt.Fprintf(os.Stderr, "[RPC] eth_estimateGas called\n")
	// 1. Resolve Header
	header, err := api.headerByRpcBlock(ctx, blockNrOrHash)
	if err != nil {
		return nil, err
	}

	// 2. Get State
	state, err := api.bc.StateAt(header.VerkleRoot)
	if err != nil {
		return nil, err
	}

	// 3. Convert Args to Msg
	msg, err := args.ToMessage(header.GasLimit, header.BaseFee)
	if err != nil {
		return nil, err
	}
	// Fixing Nonce: If not provided, use state nonce
	if args.Nonce == nil {
		msg.Nonce = state.GetNonce(msg.From)
	}

	// 4. Execute via Executor (Simulation)
	res, err := api.executor.Call(state, header, &msg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[RPC] eth_estimateGas failed (executor): %v\n", err)
		return nil, err
	}
	if res.Failed() {
		fmt.Fprintf(os.Stderr, "[RPC] eth_estimateGas REVERTED: %v | Data: %x\n", res.Err, res.ReturnData)
		// Return a more descriptive error that Ethers/MetaMask can parse
		return nil, &revertError{
			reason: fmt.Sprintf("execution reverted: %v", res.Err),
			hex:    hexutil.Encode(res.ReturnData),
		}
	}

	// 5. Buffer
	// Add 20% buffer
	estimated := res.UsedGas + (res.UsedGas / 5)
	if estimated > header.GasLimit {
		estimated = header.GasLimit
	}
	return (*hexutil.Uint64)(&estimated), nil
}

// Call executes a new message call immediately without creating a transaction on the block chain.
func (api *PublicEthAPI) Call(ctx context.Context, args CallArgs, blockNrOrHash *rpc.BlockNumberOrHash) (hexutil.Bytes, error) {
	// 1. Resolve Header
	header, err := api.headerByRpcBlock(ctx, blockNrOrHash)
	if err != nil {
		return nil, err
	}

	// 2. State
	state, err := api.bc.StateAt(header.VerkleRoot)
	if err != nil {
		return nil, err
	}

	// 3. Msg
	msg, err := args.ToMessage(header.GasLimit, header.BaseFee)
	if err != nil {
		return nil, err
	}
	// Fixing Nonce: If not provided, use state nonce
	if args.Nonce == nil {
		msg.Nonce = state.GetNonce(msg.From)
	}

	// 4. Exec
	res, err := api.executor.Call(state, header, &msg)
	if err != nil {
		return nil, err
	}
	if res.Failed() {
		return nil, &revertError{
			reason: fmt.Sprintf("execution reverted: %v", res.Err),
			hex:    hexutil.Encode(res.ReturnData),
		}
	}
	return hexutil.Bytes(res.ReturnData), nil
}

// GetCode returns the code at a given address.
func (api *PublicEthAPI) GetCode(ctx context.Context, address common.Address, blockNrOrHash *rpc.BlockNumberOrHash) (hexutil.Bytes, error) {
	// 1. Resolve Header
	header, err := api.headerByRpcBlock(ctx, blockNrOrHash)
	if err != nil {
		return nil, err
	}
	// 2. Get State
	state, err := api.bc.StateAt(header.VerkleRoot)
	if err != nil {
		return nil, err
	}
	return state.GetCode(address), nil
}

// Internal Helper: Resolve BlockNumberOrHash to Header
func (api *PublicEthAPI) headerByRpcBlock(ctx context.Context, blockNrOrHash *rpc.BlockNumberOrHash) (*ztypes.Header, error) {
	if blockNrOrHash == nil {
		return api.bc.CurrentBlock().Header, nil
	}
	if blockNrOrHash.BlockHash != nil {
		b := api.bc.GetBlockByHash(*blockNrOrHash.BlockHash)
		if b == nil {
			return nil, fmt.Errorf("block not found")
		}
		return b.Header, nil
	}

	if blockNrOrHash.BlockNumber != nil {
		if err := api.validateBlockNumber(*blockNrOrHash.BlockNumber); err != nil {
			return nil, err
		}
		if *blockNrOrHash.BlockNumber == rpc.LatestBlockNumber {
			return api.bc.CurrentBlock().Header, nil
		}
		if *blockNrOrHash.BlockNumber == rpc.PendingBlockNumber {
			return api.bc.CurrentBlock().Header, nil // Treat pending as latest for now
		}
		if *blockNrOrHash.BlockNumber == rpc.EarliestBlockNumber {
			return api.bc.GenesisBlock().Header, nil
		}
		// Specific number
		b := api.bc.GetBlockByNumber(uint64(*blockNrOrHash.BlockNumber))
		if b == nil {
			return nil, fmt.Errorf("block not found")
		}
		return b.Header, nil
	}

	// Default to latest
	return api.bc.CurrentBlock().Header, nil
}

func (api *PublicEthAPI) GetStorageAt(ctx context.Context, address common.Address, slot string, blockNrOrHash *rpc.BlockNumberOrHash) (hexutil.Bytes, error) {
	// 1. Resolve Header
	header, err := api.headerByRpcBlock(ctx, blockNrOrHash)
	if err != nil {
		return nil, err
	}
	// 2. Get State
	state, err := api.bc.StateAt(header.VerkleRoot)
	if err != nil {
		return nil, err
	}
	// 3. Get Storage
	keyHash := common.HexToHash(slot)
	val := state.GetState(address, keyHash)
	return hexutil.Bytes(val.Bytes()), nil
}

// Syncing returns false (not syncing) or sync object.
func (api *PublicEthAPI) Syncing() (interface{}, error) {
	return false, nil
}

// Coinbase returns the mining address.
func (api *PublicEthAPI) Coinbase() (common.Address, error) {
	return api.bc.CurrentBlock().Header.Coinbase, nil
}

// Mining returns true if node is mining.
func (api *PublicEthAPI) Mining() (bool, error) {
	return true, nil // Simplified
}

// Hashrate returns current hashrate.
func (api *PublicEthAPI) Hashrate() (hexutil.Uint64, error) {
	return 0, nil
}

// Status returns the txpool status (pending and queued counts).
func (api *PublicEthAPI) Status(ctx context.Context) (map[string]hexutil.Uint64, error) {
	if api.txPool == nil {
		return nil, fmt.Errorf("txpool not available")
	}
	p, q := api.txPool.Stats()
	return map[string]hexutil.Uint64{
		"pending": hexutil.Uint64(p),
		"queued":  hexutil.Uint64(q),
	}, nil
}
func (api *PublicEthAPI) validateBlockNumber(blockNr rpc.BlockNumber) error {
	if blockNr < rpc.EarliestBlockNumber {
		return fmt.Errorf("invalid block number: %d", blockNr)
	}
	if blockNr >= 0 {
		head := api.bc.CurrentBlock().Header.Number.Uint64()
		if uint64(blockNr) > head+1024 {
			return fmt.Errorf("block number too far in future: %d > %d", blockNr, head+1024)
		}
	}
	return nil
}

// revertError is a custom error type that includes the revert data for MetaMask/Ethers compatibility
type revertError struct {
	reason string
	hex    string
}

func (e *revertError) Error() string { return e.reason }

// ErrorData allows the rpc package to include the 'data' field in the JSON response
func (e *revertError) ErrorData() interface{} { return e.hex }
