package node

import (
	"fmt"
	"time"

	"zephyria/p2p"
	"zephyria/state"
	ztypes "zephyria/types"

	"github.com/syndtr/goleveldb/leveldb"
)

// HandleP2PBlock processes incoming blocks from the P2P network.
func (n *Node) HandleP2PBlock(p *p2p.Peer, b *ztypes.Block) {
	n.stateLock.Lock()
	defer n.stateLock.Unlock()

	// 0. Duplicate Check
	// If we already have this block, we must NOT re-execute it, otherwise we will apply
	// the state changes twice to the in-memory stateDB, corrupting the verkle tree.
	if n.bc.GetBlockByHash(b.Hash()) != nil {
		return
	}

	// Import Block Logic
	// 1. Validate Signature & PoH Linkage (Security)
	var parentHeader *ztypes.Header
	parent := n.bc.GetBlockByHash(b.Header.ParentHash)
	if parent != nil {
		parentHeader = parent.Header
	}

	if err := n.engine.Verify(b, parentHeader); err != nil {
		fmt.Printf("P2P Import Rejected (Verify): %v\n", err)
		return
	}

	// 2. Execute
	receipts, root, err := n.executor.ApplyBlock(n.state, b.Header, b.Transactions)
	if err != nil {
		fmt.Printf("P2P Import Failed (Exec): %v\n", err)
		return
	}

	// CRITICAL: Do NOT overwrite the root. Verify it.
	// If we overwrite, we change the block hash, which breaks the chain (next block will have wrong parent).
	if root != b.Header.VerkleRoot {
		fmt.Printf("\033[1;31m[!] CRITICAL STATE MISMATCH\033[0m Block #%d\n", b.Header.Number.Uint64())
		fmt.Printf("    Expected: %s\n", b.Header.VerkleRoot.Hex())
		fmt.Printf("    Computed: %s\n", root.Hex())
		fmt.Printf("\033[1;33m[TIP] Local state is corrupted. Please stop the node and delete the 'zephyria-chaindata' directory.\033[0m\n")
		return // CRITICAL: Stop here to prevent further corruption
	}

	// 3. Commit State
	batch := new(leveldb.Batch)
	// Pruning Check: Every 128 blocks, prune history older than 512 blocks
	currentNum := b.Header.Number.Uint64()
	if currentNum%128 == 0 && currentNum > 512 {
		go func(limit uint64) {
			deleted := n.state.Prune(limit)
			if deleted > 0 {
				fmt.Printf("\033[1;36m[🧹] State Pruned:\033[0m Removed %d entries older than #%d\n", deleted, limit)
			}
		}(currentNum - 512)
	}
	n.state.Commit(n.bc.Database(), batch, currentNum)
	n.db.Write(batch, nil)

	// 4. Add to Chain
	if err := n.bc.AddBlock(b, receipts); err != nil {
		fmt.Printf("P2P Import Failed (Add): %v\n", err)
	} else {
		// SYNC POH METRONOME
		// Link the local cryptographic clock to the new tip
		vdfSize := (n.engine.VDFIterations / n.engine.VDFCheckpointInterval) * 32
		if len(b.Header.ExtraData) >= vdfSize {
			lastVDF := b.Header.ExtraData[vdfSize-32 : vdfSize]
			n.engine.Metronome.Sync(lastVDF, b.Header.Number.Uint64())
		}

		// Broadcast Announcement (Feedback Loop)
		if currentNum%100 == 0 || (time.Since(time.Unix(int64(b.Header.Time), 0)) < 10*time.Second) {
			fmt.Printf("\033[1;32m[+] Imported Block\033[0m #%d | Hash: %s\n", currentNum, b.Hash().Hex()[:8])
		}
		// 5. Broadcast Announcement (Feedback Loop)
		// This tells the network (and bootnodes) our new height so they keep sending Rotor shreds.
		n.p2p.BroadcastBlockAnnouncement(b.Header)

		// Efficiently update TxPool
		// Note: n.txPool access assumes it is initialized on Node
		n.txPool.StateUpdate(func() *state.StateDB { return n.state }) // Use getter or field? api.go accesses state.

		// VOTOR: Create and Gossip Vote
		// Note: n.votePool access
		if vote, err := n.engine.CreateVote(b.Hash(), b.Header.Number.Uint64()); err == nil {
			n.p2p.BroadcastVote(vote)
		}

		// Cleanup Old Votes (Keep last 128 blocks)
		if currentNum > 128 {
			n.votePool.Prune(currentNum - 128)
		}
	}
}

// HandleP2PVote processes incoming votes from the P2P network.
func (n *Node) HandleP2PVote(p *p2p.Peer, v *ztypes.Vote) {
	// Import Vote
	if n.votePool.AddVote(v) {
		// If new and valid, re-gossip (flooding)
		n.p2p.BroadcastVote(v)

		// Check QC
		if reached, _, bitmask := n.votePool.CheckQuorum(v.BlockHash); reached {
			// We found a QC!
			// In full Votor, we'd package this QC into a "Justification" for the next block.
			// For now, we just log "INSTANT FINALITY" for the block.
			fmt.Printf("\033[1;35m[⚡] BLOCK FINALIZED\033[0m: %s | QC Reached via %x\n", v.BlockHash.Hex()[:10], bitmask)
			// TODO: Commit QC to storage
		}
	}
}

// HandleP2PSlashing processes incoming slashing proofs from the P2P network.
func (n *Node) HandleP2PSlashing(p *p2p.Peer, s *ztypes.SlashingProof) error {
	// 1. Verify Proof via Consensus Engine
	if err := n.engine.HandleSlashingProof(s); err != nil {
		return err
	}

	// 2. If valid, add to Local Pool or broadcast?
	// Currently, handleSlashing in Server already broadcasts if verified.

	// 3. TODO: Propose a slashing transaction if we are the leader
	fmt.Printf("[🛡] Verified Slashing Proof for validator %s from peer %s\n", s.ValidatorAddr.Hex(), p.Addr())
	return nil
}
