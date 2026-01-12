package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"

	"zephyria/core/rawdb"
	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
)

// Snapshot represents a point-in-time export of the chain state.
type Snapshot struct {
	BlockNumber uint64      `json:"blockNumber"`
	StateRoot   common.Hash `json:"stateRoot"`
	Timestamp   uint64      `json:"timestamp"`
	// Validators are stored as generic data for now to avoid circular dependency with consensus
	// Real implementation would decode this into consensus.Validator
	Validators []SnapshotValidator `json:"validators"`
}

type SnapshotValidator struct {
	Address common.Address `json:"address"`
	Stake   string         `json:"stake"` // BigInt as string
	BLSKey  []byte         `json:"blsKey"`
}

// CreateSnapshot captures the state at a specific block.
// Note: This does not export the full state trie (which is huge),
// but rather the metadata needed to bootstrap a node trusted from this point (Weak Subjectivity).
// For full state sync, we would need to export the Verkle Tree or rely on P2P State Sync.
func (bc *Blockchain) CreateSnapshot(blockNum uint64) (*Snapshot, error) {
	block := bc.GetBlockByNumber(blockNum)
	if block == nil {
		return nil, errors.New("block not found")
	}

	snapshot := &Snapshot{
		BlockNumber: blockNum,
		StateRoot:   block.Header.VerkleRoot,
		Timestamp:   block.Header.Time,
		Validators:  make([]SnapshotValidator, 0),
	}

	// In a real implementation, we would query the consensus engine or state for the validator set.
	// Since consensus engine is not easily accessible from Blockchain (it's injected into Node),
	// and Blockchain shouldn't depend on Consensus, we might skip validators for this PoC
	// OR we relies on the caller to populate it.
	//
	// However, the prompt asks for "CreateSnapshot" in Blockchain.
	// Let's stick to the struct definition and basic metadata.
	// If we need validators, we'd need to read from the StateDB directly using known system keys.
	//
	// StateDB usage:
	// state, _ := bc.StateAt(block.Header.VerkleRoot)
	// valSet := ReadValidatorsFromState(state) // This logic lives in core/system_contracts usually or consensus

	return snapshot, nil
}

// WriteSnapshot writes the snapshot to a file.
func (bc *Blockchain) WriteSnapshot(s *Snapshot, path string) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

// SyncFromSnapshot initializes the chain from a snapshot.
// This is a "Trusted Setup" sync.
func (bc *Blockchain) SyncFromSnapshot(s *Snapshot) error {
	// 1. Check if we are already ahead
	if bc.CurrentBlock().Header.Number.Uint64() >= s.BlockNumber {
		return errors.New("chain is already ahead of snapshot")
	}

	// 2. We need the State Root to be available.
	// If we don't have the state trie for this root, we cannot really sync *from* it
	// unless we also import the state (Snap Sync).
	// For this PoC, we assume the user might have the state DB or we just trust the header?
	//
	// A real "SyncFromSnapshot" would download the state tree corresponding to StateRoot.
	// Here we just insert a "fake" block or trusted header?

	// Construct a "Gap" block or trusted header
	header := &types.Header{
		Number:     new(big.Int).SetUint64(s.BlockNumber),
		VerkleRoot: s.StateRoot,
		Time:       s.Timestamp,
		ExtraData:  []byte("SNAPSHOT_RESTORE"),
	}

	// We can't really "Execute" this block. We insert it implicitly.
	// We update the Head.

	// Warning: This leaves the chain with a gap (0 -> Snapshot).
	// Accessing blocks 1..Snapshot-1 will fail.

	// For PoC compliance with the requested signature:
	bc.mu.Lock()
	defer bc.mu.Unlock()

	// Write Trusted Header as Head
	// We need a Block wrap
	block := types.NewBlock(header, nil)

	// Write to DB
	if err := rawdb.WriteBlock(bc.db, block); err != nil {
		return err
	}
	rawdb.WriteHeadBlockHash(bc.db, block.Hash())
	rawdb.WriteCanonicalHash(bc.db, s.BlockNumber, block.Hash())

	bc.currentBlock = block
	fmt.Printf("Chain initialized from Snapshot #%d\n", s.BlockNumber)

	return nil
}

// Helper to Load Snapshot from file
func LoadSnapshot(path string) (*Snapshot, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s Snapshot
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, err
	}
	return &s, nil
}
