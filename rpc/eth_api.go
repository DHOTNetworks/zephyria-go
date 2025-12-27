package rpc

import (
	"context"
	"fmt"
	"math/big"

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
	txCh     chan *types.Transaction
	executor *core.Executor // Added for simulation
}

func NewPublicEthAPI(bc *core.Blockchain, s *state.StateDB, txCh chan *types.Transaction, executor *core.Executor) *PublicEthAPI {
	return &PublicEthAPI{
		bc:       bc,
		statedb:  s,
		txCh:     txCh,
		executor: executor,
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
	var stateDB *state.StateDB = api.statedb
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
	tx := new(types.Transaction)
	if err := rlp.DecodeBytes(data, tx); err != nil {
		return common.Hash{}, err
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

	// Send to main loop
	if api.txCh == nil {
	} else {
	}

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

	// Force Legacy: Do NOT include baseFeePerGas
	// if block.Header.BaseFee != nil {
	// 	res["baseFeePerGas"] = (*hexutil.Big)(block.Header.BaseFee)
	// }

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
		"difficulty":       (*hexutil.Big)(block.Header.Difficulty),
		"totalDifficulty":  (*hexutil.Big)(block.Header.Difficulty),
		"extraData":        hexutil.Bytes(block.Header.ExtraData),
		"size":             hexutil.Uint64(1000),
		"gasLimit":         hexutil.Uint64(block.Header.GasLimit),
		"gasUsed":          hexutil.Uint64(block.Header.GasUsed),
		"timestamp":        hexutil.Uint64(block.Header.Time),
		"uncles":           []common.Hash{},
	}
	// Force Legacy: Do NOT include baseFeePerGas
	// if block.Header.BaseFee != nil {
	// 	res["baseFeePerGas"] = (*hexutil.Big)(block.Header.BaseFee)
	// }

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

// FeeHistory (EIP-1559) - Disabled
func (api *PublicEthAPI) FeeHistory(ctx context.Context, blockCount rpc.BlockNumber, lastBlock rpc.BlockNumber, rewardPercentiles []float64) (map[string]interface{}, error) {
	// Return empty or error to force Legacy fallback in wallets
	return nil, fmt.Errorf("fee history not supported (legacy chain)")
}

// EstimateGas estimates gas usage for the transaction.
func (api *PublicEthAPI) EstimateGas(ctx context.Context, args CallArgs) (*hexutil.Uint64, error) {
	// 1. Resolve State/Header (default to pending/latest)
	// For robustness: Use Latest.
	header := api.bc.CurrentBlock().Header

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
		return nil, err
	}
	if res.Failed() {
		return nil, fmt.Errorf("simulation failed: %v", res.Err)
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
func (api *PublicEthAPI) Call(ctx context.Context, args CallArgs, blockNrOrHash rpc.BlockNumberOrHash) (hexutil.Bytes, error) {
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
		return nil, res.Err
	}
	return hexutil.Bytes(res.ReturnData), nil
}

// GetCode returns the code at a given address.
func (api *PublicEthAPI) GetCode(ctx context.Context, address common.Address, blockNrOrHash rpc.BlockNumberOrHash) (hexutil.Bytes, error) {
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
func (api *PublicEthAPI) headerByRpcBlock(ctx context.Context, blockNrOrHash rpc.BlockNumberOrHash) (*ztypes.Header, error) {
	if blockNrOrHash.BlockHash != nil {
		b := api.bc.GetBlockByHash(*blockNrOrHash.BlockHash)
		if b == nil {
			return nil, fmt.Errorf("block not found")
		}
		return b.Header, nil
	}

	if blockNrOrHash.BlockNumber != nil {
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

func (api *PublicEthAPI) GetStorageAt(ctx context.Context, address common.Address, slot string, blockNrOrHash rpc.BlockNumberOrHash) (hexutil.Bytes, error) {
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
