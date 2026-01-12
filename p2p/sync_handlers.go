package p2p

import (
	"fmt"
	"time"

	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	"github.com/syndtr/goleveldb/leveldb"
)

func (s *Server) handleNewBlock(p *Peer, msg *NewBlockMsg) {
	block := msg.Block
	if block == nil {
		return
	}

	// Update Peer State (Head Tracking)
	if block.Header.Number.Uint64() > p.HeadNumber {
		p.HeadNumber = block.Header.Number.Uint64()
		p.HeadHash = block.Hash().Hex()
	}

	// Check against local chain
	if s.Blockchain.GetBlockByHash(block.Hash()) != nil {
		return
	}

	// Gap Detection (REACTIVE)
	current := s.Blockchain.CurrentBlock().Header.Number.Uint64()
	if block.Header.Number.Uint64() > current+1 {
		if !s.Syncer.IsSyncing() {
			s.Syncer.CheckAndStart(p)
		}
		return
	}

	// Enqueue for processing.
	s.ingressCh <- &ingressBlock{Peer: p, Block: block}
}

func (s *Server) handleGetBlocks(p *Peer, msg *GetBlocksMsg) {
	var blocks []*types.Block
	startBlock := s.Blockchain.GetBlockByHash(msg.StartHash)
	if startBlock != nil {
		startNum := startBlock.Header.Number.Uint64()
		for i := uint64(0); i < msg.Limit; i++ {
			b := s.Blockchain.GetBlockByNumber(startNum + 1 + i)
			if b == nil {
				break
			}
			blocks = append(blocks, b)
		}
	}
	p.Send(&BlocksMsg{Blocks: blocks})
}

func (s *Server) handleBlocks(p *Peer, msg *BlocksMsg) {
	// If Pipeline Sync is active, route to Syncer
	if s.Syncer.IsSyncing() {
		s.Syncer.OnBodiesReceived(msg.Blocks)
		return
	}

	// Standard Propagation
	// fmt.Printf("\033[1;34m[📥] Recv %d blocks from Sync\033[0m\n", len(msg.Blocks))
	for _, b := range msg.Blocks {
		// Sync Improvement: Wait if ingress is full instead of dropping
		// This prevents "stuck" sync where blocks are lost.
		s.ingressCh <- &ingressBlock{Peer: p, Block: b}
	}
}

func (s *Server) handleGetHeaders(p *Peer, msg *GetHeadersMsg) {
	// fmt.Printf("DEBUG: handleGetHeaders from %s (Hash: %s, Num: %d, Limit: %d)\n", p.conn.RemoteAddr(), msg.StartHash.Hex(), msg.StartNumber, msg.Limit)
	var headers []*types.Header
	var startBlock *types.Block
	if msg.StartHash != (common.Hash{}) {
		startBlock = s.Blockchain.GetBlockByHash(msg.StartHash)
	} else {
		startBlock = s.Blockchain.GetBlockByNumber(msg.StartNumber)
	}

	if startBlock != nil {
		startNum := startBlock.Header.Number.Uint64()
		offset := uint64(1)
		// If requesting by Number, include the start block (Inclusive)
		if msg.StartHash == (common.Hash{}) {
			offset = 0
		}

		for i := uint64(0); i < msg.Limit; i++ {
			b := s.Blockchain.GetBlockByNumber(startNum + offset + i)
			if b == nil {
				break
			}
			headers = append(headers, b.Header)
		}
	}
	// fmt.Printf("DEBUG: Sending %d headers to %s\n", len(headers), p.conn.RemoteAddr())
	p.Send(&HeadersMsg{Headers: headers})
}

func (s *Server) handleGetBodies(p *Peer, msg *GetBodiesMsg) {
	// fmt.Printf("DEBUG: handleGetBodies from %s (%d hashes)\n", p.conn.RemoteAddr(), len(msg.BlockHashes))
	var blocks []*types.Block
	for _, hash := range msg.BlockHashes {
		b := s.Blockchain.GetBlockByHash(hash)
		if b != nil {
			blocks = append(blocks, b)
		}
	}
	p.Send(&BodiesMsg{Blocks: blocks})
}

func (s *Server) handleGetSnap(p *Peer, msg *GetSnapMsg) {
	db := s.Blockchain.Database()
	iter := db.NewIterator(nil, nil)
	defer iter.Release()

	if len(msg.SeekKey) > 0 {
		iter.Seek(msg.SeekKey)
	}

	items := make([]SnapItem, 0, msg.Limit)
	count := uint32(0)

	for iter.Next() {
		if count >= msg.Limit {
			break
		}
		key := make([]byte, len(iter.Key()))
		copy(key, iter.Key())
		val := make([]byte, len(iter.Value()))
		copy(val, iter.Value())
		items = append(items, SnapItem{Key: key, Value: val})
		count++
	}

	p.Send(&SnapDataMsg{Items: items})
}

func (s *Server) handleSnapData(p *Peer, msg *SnapDataMsg) {
	fmt.Printf("\033[1;36m[📸] SnapSync: Received %d items\033[0m\n", len(msg.Items))
	batch := new(leveldb.Batch)
	for _, item := range msg.Items {
		batch.Put(item.Key, item.Value)
	}
	if err := s.Blockchain.Database().Write(batch, nil); err != nil {
		fmt.Printf("SnapSync Write Error: %v\n", err)
	}

	if len(msg.Items) > 0 {
		lastKey := msg.Items[len(msg.Items)-1].Key
		go func() {
			time.Sleep(100 * time.Millisecond)
			nextKey := make([]byte, len(lastKey))
			copy(nextKey, lastKey)
			for i := len(nextKey) - 1; i >= 0; i-- {
				nextKey[i]++
				if nextKey[i] != 0 {
					break
				}
			}
			p.Send(&GetSnapMsg{SeekKey: nextKey, Limit: 1000})
		}()
	} else {
		fmt.Printf("\033[1;32m[📸] SnapSync: Completed.\033[0m\n")
	}
}
