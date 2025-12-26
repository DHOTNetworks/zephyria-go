package core

import (
	"errors"
	"fmt"
	"sync"

	"zephyria/core/rawdb"
	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
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
	headHash := rawdb.ReadHeadBlockHash(db)
	if headHash == (common.Hash{}) {
		// Initialize Genesis from hardcoded parameters
		genesis := GenerateGenesisBlock(cfg)
		if err := bc.AddBlock(genesis, nil); err != nil {
			fmt.Printf("CRITICAL: Failed to add genesis block: %v\n", err)
		} else {
			rawdb.WriteHeadBlockHash(db, genesis.Hash())
			// log written
		}
		bc.currentBlock = genesis
		fmt.Printf("\033[1;32m[✨] Initialized Genesis Block\033[0m | Hash: %s\n", genesis.Hash().Hex()[:10])
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
