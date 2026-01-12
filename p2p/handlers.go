package p2p

import (
	"fmt"
	"io"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rlp"
)

// Handling Messages
// handleMessageStream decodes an object from the stream based on the code.
func (s *Server) handleMessageStream(p *Peer, code uint64, r io.Reader) {
	// fmt.Printf("DEBUG: p2p message received from %s: code=%d\n", p.conn.RemoteAddr(), code)

	// AUTH: Enforce Handshake First
	if !p.HandshakeComplete && code != MsgStatus {
		fmt.Printf("\033[1;31m[!] Protocol Violation:\033[0m Peer %s sent msg %d before Status. Dropping.\n", p.conn.RemoteAddr(), code)
		s.RemovePeer(p)
		return
	}

	switch code {
	case MsgStatus:
		var msg StatusMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleStatus(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode StatusMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgNewBlock:
		if !p.blockLimiter.Allow() {
			fmt.Printf("\033[1;31m[🛡] Rate Limit Exceeded:\033[0m Peer %s sent too many Blocks. Dropping.\n", p.conn.RemoteAddr())
			return // Drop message (or could disconnect)
		}
		var msg NewBlockMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleNewBlock(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode NewBlockMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgGetBlocks:
		var msg GetBlocksMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleGetBlocks(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode GetBlocksMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgBlocks:
		var msg BlocksMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleBlocks(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode BlocksMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgAuth:
		var msg AuthMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleAuth(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode AuthMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgTx:
		if !p.txLimiter.Allow() {
			// lighter log for tx spam
			// fmt.Printf("Rate Limit: Peer %s sent too many Txs.\n", p.conn.RemoteAddr())
			return
		}
		var msg TxMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleTx(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode TxMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgVote:
		if !p.voteLimiter.Allow() {
			fmt.Printf("\033[1;31m[🛡] Rate Limit Exceeded:\033[0m Peer %s sent too many Votes.\n", p.conn.RemoteAddr())
			return
		}
		var msg VoteMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleVote(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode VoteMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgBlockShred:
		var msg BlockShredMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleBlockShred(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode BlockShredMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgPing:
		s.handlePing(p)
	case MsgPong:
	case MsgGetHeaders:
		var msg GetHeadersMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleGetHeaders(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode GetHeadersMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgHeaders:
		var msg HeadersMsg
		if err := rlp.Decode(r, &msg); err == nil {
			// Update Peer Head Tracking
			if len(msg.Headers) > 0 {
				lastHeader := msg.Headers[len(msg.Headers)-1]
				if lastHeader.Number.Uint64() > p.HeadNumber {
					p.HeadNumber = lastHeader.Number.Uint64()
					p.HeadHash = lastHeader.Hash().Hex() // Helper or just Hex()
				}
			}
			s.Syncer.OnHeadersReceived(msg.Headers, p)
		} else {
			fmt.Printf("ERROR: Failed to decode HeadersMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgGetBodies:
		var msg GetBodiesMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleGetBodies(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode GetBodiesMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgBodies:
		var msg BodiesMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.Syncer.OnBodiesReceived(msg.Blocks)
		} else {
			fmt.Printf("ERROR: Failed to decode BodiesMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgSlashing:
		var msg SlashingMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleSlashing(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode SlashingMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgGetSnap:
		var msg GetSnapMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleGetSnap(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode GetSnapMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgSnapData:
		var msg SnapDataMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleSnapData(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode SnapDataMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgGetPeers:
		var msg GetPeersMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleGetPeers(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode GetPeersMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgPeers:
		var msg PeersMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handlePeers(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode PeersMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgAnnouncement:
		var msg AnnouncementMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleAnnouncement(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode AnnouncementMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgTxsInv:
		var msg TxsInvMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleTxsInv(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode TxsInvMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	case MsgGetTxs:
		var msg GetTxsMsg
		if err := rlp.Decode(r, &msg); err == nil {
			s.handleGetTxs(p, &msg)
		} else {
			fmt.Printf("ERROR: Failed to decode GetTxsMsg from %s: %v\n", p.conn.RemoteAddr(), err)
		}
	default:
		fmt.Printf("WARNING: Unknown Message Code from %s: %d\n", p.conn.RemoteAddr(), code)
	}
}

func (s *Server) handleTx(p *Peer, msg *TxMsg) {
	if s.TxPool == nil {
		return
	}

	// Add to pool
	isNew, err := s.TxPool.Add(msg.Tx)
	if err != nil {
		return
	}

	if isNew {
		serverMsg := &TxMsg{Tx: msg.Tx}
		s.peerLock.RLock()
		for peer := range s.peers {
			if peer != p {
				peer.Send(serverMsg)
			}
		}
		s.peerLock.RUnlock()
	}
}

func (s *Server) handleStatus(p *Peer, msg *StatusMsg) {
	cfg := s.Blockchain.Config()

	if msg.GenesisHash != cfg.GenesisHash || msg.NetworkID != cfg.ChainID.Uint64() {
		fmt.Printf("\033[1;31m[!] Peer Rejected:\033[0m %s (Genesis/Network Mismatch)\n", p.conn.RemoteAddr())
		s.RemovePeer(p)
		return
	}

	fmt.Printf("\033[1;32m[+] Peer Connected:\033[0m %s | Head #%d (%s)\033[0m\n", p.conn.RemoteAddr(), msg.HeadNumber, msg.HeadHash.Hex()[:10])
	p.HeadHash = msg.HeadHash.Hex()
	p.HeadNumber = msg.HeadNumber

	current := s.Blockchain.CurrentBlock().Header.Number.Uint64()
	if msg.HeadNumber > current {
		s.Syncer.CheckAndStart(p)
	}

	// Handshake Successful
	p.HandshakeComplete = true
	s.Syncer.RegisterPeer(p)

	if s.PeerCount() < 5 {
		p.Send(&GetPeersMsg{})
	}

	if s.Config.PrivateKey != nil {
		hash := crypto.Keccak256(msg.Challenge)
		sig, err := crypto.Sign(hash, s.Config.PrivateKey)
		if err == nil {
			auth := &AuthMsg{
				Signature: sig,
				PublicKey: crypto.FromECDSAPub(&s.Config.PrivateKey.PublicKey),
			}
			p.Send(auth)
		}
	}
}

func (s *Server) handlePing(p *Peer) {
	p.Send(&PongMsg{})
}

func (s *Server) handleAnnouncement(p *Peer, msg *AnnouncementMsg) {
	if msg.Header == nil {
		return
	}
	if msg.Header.Number.Uint64() > p.HeadNumber {
		p.HeadNumber = msg.Header.Number.Uint64()
		p.HeadHash = msg.Header.Hash().Hex()
	}
}

func (s *Server) handleAuth(p *Peer, msg *AuthMsg) {
	hash := crypto.Keccak256(p.Challenge)
	recoveredPub, err := crypto.SigToPub(hash, msg.Signature)
	if err != nil {
		s.RemovePeer(p)
		return
	}

	addr := crypto.PubkeyToAddress(*recoveredPub)
	cfg := s.Blockchain.Config()
	isValidator := false
	for _, v := range cfg.Validators {
		if v.Address == addr {
			isValidator = true
			break
		}
	}

	if isValidator {
		fmt.Printf("\033[1;32m[🛡] Shield Verified:\033[0m Peer %s is VALIDATOR %s. Priority Access Granted.\n", p.conn.RemoteAddr(), addr.Hex()[:10])
		p.IsTrusted = true
		id := PubkeyToNodeID(recoveredPub)
		s.Discovery.MarkVerified(id)
	} else {
		p.IsTrusted = false
	}
}

func (s *Server) handleGetPeers(p *Peer, msg *GetPeersMsg) {
	peers := s.Discovery.GetRandomPeers(16)
	p.Send(&PeersMsg{Nodes: peers})
}

func (s *Server) handlePeers(p *Peer, msg *PeersMsg) {
	for _, n := range msg.Nodes {
		if n.IP == nil || n.Port == 0 || n.ID == s.Discovery.SelfID {
			continue
		}
		s.Discovery.AddPeer(n)
	}
}

func (s *Server) handleVote(p *Peer, msg *VoteMsg) {
	if s.OnVoteRecv != nil {
		s.OnVoteRecv(p, msg.Vote)
	}
}

func (s *Server) handleSlashing(p *Peer, msg *SlashingMsg) {
	fmt.Printf("\033[1;33m[!] P2P Slashing Proof Received:\033[0m Target %s from %s\n", msg.Proof.ValidatorAddr.Hex(), p.conn.RemoteAddr())

	// 1. Send to Consensus Engine for local verification and possible propagation
	if s.OnSlashingRecv != nil {
		if err := s.OnSlashingRecv(p, msg.Proof); err != nil {
			fmt.Printf("Slashing Proof Rejected by Engine: %v\n", err)
			return
		}
	}

	// 2. Gossip to other peers
	s.Broadcast(MsgSlashing, msg)
}

func (s *Server) handleTxsInv(p *Peer, msg *TxsInvMsg) {
	if s.TxPool == nil {
		return
	}
	missing := make([]common.Hash, 0)
	for _, hash := range msg.Hashes {
		if s.TxPool.Get(hash) == nil {
			missing = append(missing, hash)
		}
	}
	if len(missing) > 0 {
		p.Send(&GetTxsMsg{Hashes: missing})
	}
}

func (s *Server) handleGetTxs(p *Peer, msg *GetTxsMsg) {
	if s.TxPool == nil {
		return
	}
	for _, hash := range msg.Hashes {
		if tx := s.TxPool.Get(hash); tx != nil {
			p.Send(&TxMsg{Tx: tx})
		}
	}
}
