package core

import (
	"errors"
	"fmt"
	"math/big"
	"sync"

	"zephyria/core/rawdb"
	"zephyria/state"
	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/params"
	"github.com/syndtr/goleveldb/leveldb"
)

var (
	ErrBlockKnown = errors.New("block already exists")
	ErrNoGenesis  = errors.New("genesis not found")
)

// Blockchain maintains the state of the chain.
type Blockchain struct {
	mu           sync.RWMutex
	db           *leveldb.DB
	config       *NetworkConfig
	currentBlock *types.Block
}

// NewBlockchain creates a new Blockchain instance.
func NewBlockchain(db *leveldb.DB, cfg *NetworkConfig) *Blockchain {
	bc := &Blockchain{
		db:     db,
		config: cfg,
	}

	// Load head
	// Load head
	headHash := rawdb.ReadHeadBlockHash(db)
	if headHash == (common.Hash{}) {
		// Initialize Genesis
		genesis := GenerateGenesisBlock(cfg)

		// Apply Genesis Allocation
		// Create a temporary state to apply allocations
		statedb := state.New(common.Hash{}, db)
		alloc := GenesisAlloc(cfg)
		for addr, balance := range alloc {
			fmt.Printf("DEBUG: Genesis AddBalance: %s = %s\n", addr.Hex(), balance.String())
			statedb.AddBalance(addr, balance, tracing.BalanceIncreaseGenesisBalance)
		}
		// Commit Genesis State
		batch := new(leveldb.Batch)
		root, err := statedb.Commit(db, batch)
		if err != nil {
			panic(fmt.Sprintf("Failed to commit genesis state: %v", err))
		}
		// Write the batch to DB
		if err := db.Write(batch, nil); err != nil {
			panic(fmt.Sprintf("Failed to write genesis batch: %v", err))
		}

		// Update Genesis Header
		genesis.Header.VerkleRoot = root
		// Re-hash block (create new wrapper to cache hash)
		genesis = types.NewBlock(genesis.Header, nil)

		if err := bc.AddBlock(genesis, nil); err != nil {
			fmt.Printf("CRITICAL: Failed to add genesis block: %v\n", err)
		} else {
			rawdb.WriteHeadBlockHash(db, genesis.Hash())
			// Also write generic database keys if strictly needed
		}
		bc.currentBlock = genesis
		fmt.Printf("\033[1;32m[✨] Initialized Genesis Block\033[0m | Hash: %s | Root: %s\n", genesis.Hash().Hex()[:10], root.Hex()[:10])
	} else {
		// Load existing head
		bc.currentBlock = rawdb.ReadBlock(db, headHash)
		fmt.Printf("\033[1;34m[⛓] Loaded Chain Head:\033[0m #%d | Hash: %s\n", bc.currentBlock.Header.Number, headHash.Hex()[:10])
	}

	return bc
}

// AddBlock adds a block to the chain.
func (bc *Blockchain) AddBlock(b *types.Block, receipts []*types.Receipt) error {
	bc.mu.Lock()
	defer bc.mu.Unlock()

	hash := b.Hash()
	if rawdb.ReadBlock(bc.db, hash) != nil {
		return ErrBlockKnown
	}

	// 1. Write Block Body and Header
	if err := rawdb.WriteBlock(bc.db, b); err != nil {
		return err
	}

	// 2. Write Receipts (if provided)
	if receipts != nil {
		if err := rawdb.WriteReceipts(bc.db, b, receipts); err != nil {
			return err
		}
	}

	// 3. Write Transaction Indices
	if err := rawdb.WriteTxLookupEntries(bc.db, b); err != nil {
		return err
	}

	// 4. Update head if newer
	if bc.currentBlock == nil || b.Header.Number.Cmp(bc.currentBlock.Header.Number) > 0 {
		bc.currentBlock = b
		rawdb.WriteHeadBlockHash(bc.db, hash)
	}

	// 5. Write Canonical Hash mapping
	rawdb.WriteCanonicalHash(bc.db, b.Header.Number.Uint64(), hash)

	return nil
}

// GetBlockByHash returns a block by its hash.
func (bc *Blockchain) GetBlockByHash(hash common.Hash) *types.Block {
	bc.mu.RLock()
	defer bc.mu.RUnlock()
	return rawdb.ReadBlock(bc.db, hash)
}

// GetBlockByNumber returns a block by its number.
func (bc *Blockchain) GetBlockByNumber(number uint64) *types.Block {
	bc.mu.RLock()
	defer bc.mu.RUnlock()
	hash := rawdb.ReadCanonicalHash(bc.db, number)
	if hash == (common.Hash{}) {
		return nil
	}
	return rawdb.ReadBlock(bc.db, hash)
}

// GenesisBlock returns the genesis block (hash of number 0).
func (bc *Blockchain) GenesisBlock() *types.Block {
	// Optimization: could cache genesis
	return bc.GetBlockByNumber(0)
}

// Config returns the network configuration.
func (bc *Blockchain) Config() *NetworkConfig {
	return bc.config
}

// CurrentBlock returns the latest block.
func (bc *Blockchain) CurrentBlock() *types.Block {
	bc.mu.RLock()
	defer bc.mu.RUnlock()
	return bc.currentBlock
}

// Database returns the underlying database.
func (bc *Blockchain) Database() *leveldb.DB {
	return bc.db
}

// StateAt returns a new state database for the given block root.
func (bc *Blockchain) StateAt(root common.Hash) (*state.StateDB, error) {
	return state.New(root, bc.db), nil
}

// CalcBaseFee implementation of EIP-1559 base fee calculation
func CalcBaseFee(config *params.ChainConfig, parent *types.Header) *big.Int {
	if parent.Number.Uint64() < config.LondonBlock.Uint64() {
		return new(big.Int).SetUint64(params.InitialBaseFee)
	}

	// Safety handle for retconned chain: if parent didn't have BaseFee, start now
	if parent.BaseFee == nil {
		return new(big.Int).SetUint64(params.InitialBaseFee)
	}

	parentGasTarget := parent.GasLimit / config.ElasticityMultiplier()

	if parent.GasUsed == parentGasTarget {
		return new(big.Int).Set(parent.BaseFee)
	}

	if parent.GasUsed > parentGasTarget {
		gasUsedDelta := parent.GasUsed - parentGasTarget
		x := new(big.Int).SetUint64(gasUsedDelta)
		y := new(big.Int).SetUint64(parentGasTarget)
		z := new(big.Int).SetUint64(8)

		// delta = (parent.BaseFee * gasUsedDelta) / (parentGasTarget * denominator)
		num := new(big.Int).Mul(parent.BaseFee, x)
		den := new(big.Int).Mul(y, z)
		delta := new(big.Int).Div(num, den)
		if delta.Cmp(big.NewInt(1)) < 0 {
			delta.SetInt64(1)
		}
		return new(big.Int).Add(parent.BaseFee, delta)
	} else {
		gasUnusedDelta := parentGasTarget - parent.GasUsed
		x := new(big.Int).SetUint64(gasUnusedDelta)
		y := new(big.Int).SetUint64(parentGasTarget)
		z := new(big.Int).SetUint64(8)

		num := new(big.Int).Mul(parent.BaseFee, x)
		den := new(big.Int).Mul(y, z)
		delta := new(big.Int).Div(num, den)

		// Cannot decrease below floor (1 Gwei)
		floor := big.NewInt(1000000000)
		nextBaseFee := new(big.Int).Sub(parent.BaseFee, delta)
		if nextBaseFee.Cmp(floor) < 0 {
			return floor
		}
		return nextBaseFee
	}
}
