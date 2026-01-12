package p2p

import (
	"fmt"
	"zephyria/types"
)

func (s *Server) handleBlockShred(p *Peer, msg *BlockShredMsg) {
	shred := msg.Shred

	// SECURITY: Verify Signature
	if err := shred.Verify(); err != nil {
		// fmt.Printf("DEBUG: Dropping invalid shred from %s: %v\n", p.conn.RemoteAddr(), err)
		return
	}

	h := shred.BlockHash

	s.shredLock.Lock()

	// 0. Deduplication check
	if s.DonePool[h] {
		s.shredLock.Unlock()
		return
	}

	if _, ok := s.ShredPool[h]; !ok {
		s.ShredPool[h] = make(map[uint64][]byte)
	}
	s.ShredPool[h][shred.Index] = shred.Data

	// 1. Check if we have enough to reconstruct
	if len(s.ShredPool[h]) < DataShards {
		s.shredLock.Unlock()
		return
	}

	// 2. Check if already imported (Blockchain check)
	if s.Blockchain.GetBlockByHash(h) != nil {
		delete(s.ShredPool, h)
		s.DonePool[h] = true // Mark as done since it's in chain
		s.shredLock.Unlock()
		return
	}

	// 3. Take ownership of reconstruction
	shreds := s.ShredPool[h]
	delete(s.ShredPool, h)
	s.DonePool[h] = true // POSITIVE deduplication

	// DONE POOL PRUNING (Maintain reasonable size)
	if len(s.DonePool) > 1000 {
		// Prune oldest? Just clear it for simplicity in PoC or pick one
		// Actually, let's just clear 100 random if we hit limit
		for k := range s.DonePool {
			delete(s.DonePool, k)
			if len(s.DonePool) < 900 {
				break
			}
		}
	}
	s.shredLock.Unlock()

	// 4. Heavy Reconstruction (Outside lock)
	block, err := s.Rotor.Reconstruct(shreds, 0)
	if err != nil {
		return
	}

	// Success!
	// ROTOR: The "Alpenglow" feature ensures high availability for live blocks.
	fmt.Printf("\033[1;32m[🧩] Rotor:\033[0m Reconstructed Block #%d | Hash: %s\n", block.Header.Number, block.Hash().Hex()[:10])

	// If syncing, route to Syncer pipeline
	if s.Syncer.IsSyncing() {
		s.Syncer.OnBodiesReceived([]*types.Block{block})
		return
	}

	s.ingressCh <- &ingressBlock{Peer: p, Block: block}
}
