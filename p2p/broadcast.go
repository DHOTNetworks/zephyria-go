package p2p

import (
	"fmt"

	"zephyria/types"

	ethtypes "github.com/ethereum/go-ethereum/core/types"
)

// BroadcastBlock propagates a block.
// ROTOR: We use a hybrid approach.
// 1. Send FULL BLOCK to sqrt(N) random peers (to ensure low latency for some).
// 2. Send SHREDS to everyone else (bandwidth saving).
func (s *Server) BroadcastBlock(block *types.Block) {
	// Encode Shreds
	shreds, err := s.Rotor.ShredBlock(block, s.Config.PrivateKey)
	if err != nil {
		fmt.Printf("Rotor Shred Error: %v\n", err)
		return
	}

	s.peerLock.RLock()
	peers := make([]*Peer, 0, len(s.peers))
	for p := range s.peers {
		peers = append(peers, p)
	}
	s.peerLock.RUnlock()

	// Turbine distribution: Spread shreds across all peers.
	currentHeight := block.Header.Number.Uint64()
	for i, sh := range shreds {
		if len(peers) == 0 {
			break
		}
		target := peers[i%len(peers)]

		// Customization: Skip Rotor pods for syncing peers (>128 behind)
		if target.HeadNumber+128 < currentHeight {
			continue
		}

		target.Send(&BlockShredMsg{Shred: sh})
	}

	// 2. Head Update: Ensure everyone knows the new tip
	// We send a lightweight announcement (Header only) to everyone.
	announcement := &AnnouncementMsg{Header: block.Header}
	fullBlockMsg := &NewBlockMsg{Block: block}

	for _, p := range peers {
		if p.HeadNumber+128 < currentHeight {
			p.Send(fullBlockMsg)
		} else {
			p.Send(announcement)
		}
	}
}

// BroadcastBlockAnnouncement sends a lightweight height update to all peers.
// This is used as a feedback loop so peers know the node has advanced.
func (s *Server) BroadcastBlockAnnouncement(header *types.Header) {
	msg := &AnnouncementMsg{Header: header}
	s.peerLock.RLock()
	defer s.peerLock.RUnlock()
	for p := range s.peers {
		p.Send(msg)
	}
}

// BroadcastVote floods a vote to all peers.
func (s *Server) BroadcastVote(vote *types.Vote) {
	msg := &VoteMsg{Vote: vote}
	s.peerLock.RLock()
	defer s.peerLock.RUnlock()
	for p := range s.peers {
		p.Send(msg)
	}
}

// BroadcastTx floods a transaction to all peers.
func (s *Server) BroadcastTx(tx *ethtypes.Transaction) {
	msg := &TxMsg{Tx: tx}
	s.peerLock.RLock()
	defer s.peerLock.RUnlock()
	for p := range s.peers {
		p.Send(msg)
	}
}
