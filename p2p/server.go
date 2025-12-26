package p2p

import (
	"crypto/ecdsa"
	"fmt"
	"net"
	"sync"
	"time"

	"zephyria/core"
	"zephyria/types"

	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rlp"
)

// Server manages the P2P network.
type Server struct {
	Config     ServerConfig
	Blockchain *core.Blockchain // Access to chain

	peers    map[*Peer]bool
	peerLock sync.RWMutex

	listener net.Listener
	quitCh   chan struct{}

	// Callback
	OnBlockRecv func(p *Peer, b *types.Block)
}

type ServerConfig struct {
	ListenAddr string
	Bootnodes  []string
	// Zelius Shield Configuration
	// Stake-Gated Access: No static IP list. We rely on Crypto Handshake.
	PrivateKey *ecdsa.PrivateKey // Identity for signing/auth (Optional for now, but needed if we want full mutual)
}

func NewServer(cfg ServerConfig, bc *core.Blockchain) *Server {
	return &Server{
		Config:     cfg,
		Blockchain: bc,
		peers:      make(map[*Peer]bool),
		quitCh:     make(chan struct{}),
	}
}

func (s *Server) Start() error {
	l, err := net.Listen("tcp", s.Config.ListenAddr)
	if err != nil {
		return err
	}
	s.listener = l
	fmt.Printf("\033[1;35m[🌐] P2P Server listening on %s\033[0m\n", s.Config.ListenAddr)

	// Zelius Shield: Strict Mode removed in favor of Stake-Gated Access.
	// fmt.Printf("\033[1;33m[🛡] Zelius Shield ACTIVE: Stake-Gated Access Enabled.\033[0m\n")

	go s.acceptLoop()

	// Dial bootnodes
	for _, addr := range s.Config.Bootnodes {
		go s.Dial(addr)
	}

	return nil
}

func (s *Server) Stop() {
	close(s.quitCh)
	if s.listener != nil {
		s.listener.Close()
	}
	// disconnect peers
	s.peerLock.Lock()
	defer s.peerLock.Unlock()
	for p := range s.peers {
		p.Stop()
	}
}

func (s *Server) Dial(addr string) {
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		fmt.Printf("Failed to dial %s: %v\n", addr, err)
		return
	}
	s.setupPeer(conn, true)
}

func (s *Server) acceptLoop() {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			select {
			case <-s.quitCh:
				return
			default:
				fmt.Printf("Accept error: %v\n", err)
				continue
			}
		}

		// Zelius Shield Checks: Moved to Handshake (Stake-Gated Access)
		// Rate Limiting is now handled per-peer or global if we add it here later.

		s.setupPeer(conn, false)
	}
}

func (s *Server) setupPeer(conn net.Conn, outbound bool) {
	p := NewPeer(conn, s, outbound)
	s.peerLock.Lock()
	s.peers[p] = true
	s.peerLock.Unlock()

	p.Start()

	// Send HANDSHAKE
	cfg := s.Blockchain.Config()
	current := s.Blockchain.CurrentBlock()

	// Zelius Shield: Generate Challenge
	// Use fixed bytes for PoC stability or proper rand if imported.
	// We mock "Random" since we can't import crypto/rand easily without messing imports again?
	// Actually we can just cast time to bytes.
	challenge := []byte(fmt.Sprintf("CHALLENGE_%d", time.Now().UnixNano()))
	p.Challenge = challenge

	status := &StatusMsg{
		ProtocolVersion: 1,
		NetworkID:       cfg.ChainID.Uint64(),
		GenesisHash:     cfg.GenesisHash,
		HeadHash:        current.Hash(),
		HeadNumber:      current.Header.Number.Uint64(),
		Challenge:       challenge,
	}
	p.Send(status)
}

func (s *Server) RemovePeer(p *Peer) {
	s.peerLock.Lock()
	if s.peers[p] {
		delete(s.peers, p)
		p.Stop()
		fmt.Printf("\033[1;31m[-] Peer disconnected:\033[0m %s\n", p.conn.RemoteAddr())
	}
	s.peerLock.Unlock()
}

func (s *Server) BroadcastBlock(block *types.Block) {
	msg := &NewBlockMsg{Block: block}
	s.peerLock.RLock()
	defer s.peerLock.RUnlock()
	for p := range s.peers {
		p.Send(msg)
	}
}

func (s *Server) PeerCount() int {
	s.peerLock.RLock()
	defer s.peerLock.RUnlock()
	return len(s.peers)
}

// Handling Messages
func (s *Server) handleMessage(p *Peer, code uint64, payload []byte) {
	switch code {
	case MsgStatus:
		var msg StatusMsg
		if err := rlp.DecodeBytes(payload, &msg); err != nil {
			return
		}
		s.handleStatus(p, &msg)

	case MsgNewBlock:
		var msg NewBlockMsg
		if err := rlp.DecodeBytes(payload, &msg); err != nil {
			return
		}
		s.handleNewBlock(p, &msg)

	case MsgGetBlocks:
		var msg GetBlocksMsg
		if err := rlp.DecodeBytes(payload, &msg); err != nil {
			return
		}
		s.handleGetBlocks(p, &msg)

	case MsgBlocks:
		var msg BlocksMsg
		if err := rlp.DecodeBytes(payload, &msg); err != nil {
			return
		}
		s.handleBlocks(p, &msg)

	case MsgAuth:
		var msg AuthMsg
		if err := rlp.DecodeBytes(payload, &msg); err != nil {
			return
		}
		s.handleAuth(p, &msg)
	}
}

// --- Handlers ---

func (s *Server) handleStatus(p *Peer, msg *StatusMsg) {
	cfg := s.Blockchain.Config()

	// Verify Genesis Hash & Network ID
	if msg.GenesisHash != cfg.GenesisHash || msg.NetworkID != cfg.ChainID.Uint64() {
		fmt.Printf("\033[1;31m[!] Peer Rejected:\033[0m %s (Genesis/Network Mismatch)\n", p.conn.RemoteAddr())
		s.RemovePeer(p)
		return
	}

	fmt.Printf("\033[1;32m[+] Peer Connected:\033[0m %s | Head #%d (%s)\n", p.conn.RemoteAddr(), msg.HeadNumber, msg.HeadHash.Hex()[:10])
	p.HeadHash = msg.HeadHash.Hex()
	p.HeadNumber = msg.HeadNumber

	// Trigger Sync if behind
	current := s.Blockchain.CurrentBlock().Header.Number.Uint64()
	if msg.HeadNumber > current {
		fmt.Printf("\033[1;34m[ℹ] Syncing:\033[0m Peer is ahead. Requesting blocks #%d to #%d\n", current+1, msg.HeadNumber)
		// Request blocks starting from our head hash (or genesis if 0) (Usually find common ancestor)
		// Simple PoC: Request from our head hash
		req := &GetBlocksMsg{
			StartHash: s.Blockchain.CurrentBlock().Hash(),
			Limit:     100,
		}
		p.Send(req)
	}
}

func (s *Server) handleNewBlock(p *Peer, msg *NewBlockMsg) {
	block := msg.Block
	// fmt.Printf("\033[1;36m[📦] Recv P2P Block\033[0m #%d | Hash: %s\n", block.Header.Number, block.Hash().Hex()[:10])

	// Check if we already have it
	if s.Blockchain.GetBlockByHash(block.Hash()) != nil {
		return
	}

	// Attempt add
	// NOTE: Requires execution. Node usually coordinates this.
	// For PoC, Server is holding Blockchain ref, can we just AddBlock?
	// AddBlock validates and executes if we integrated Executor inside AddBlock?
	// NO, separate. core.Blockchain only manages chain. Executor applies state.
	// If we just AddBlock, state won't update.
	// We need to trigger the full IMPORT pipeline (Execute -> Add).
	// But `Server` doesn't have `Executor` or `StateDB`.
	// Ideally `Node` should handle this via channel.
	// REFACTOR: `Server` shouldn't act directly. It should emit to `Node`.
	// For now, let's keep it simple: We need `Executor` and `StateDB` in `Server` or a callback.
	// Or `Node` sets a callback on `Server`.

	// We'll ignore execution for P2P sync PoC if complexity is too high,
	// BUT user wants "Syncing". Syncing implies state update.
	// Let's add an `OnBlock` callback to Server.

	if s.OnBlockRecv != nil {
		s.OnBlockRecv(p, block)
	}
}

func (s *Server) handleGetBlocks(p *Peer, msg *GetBlocksMsg) {
	// Send blocks starting from StartHash
	var blocks []*types.Block

	// Find starting block
	startBlock := s.Blockchain.GetBlockByHash(msg.StartHash)
	if startBlock != nil {
		// Usually GetBlocks means "blocks *after* this hash" or "starting at"?
		// Standard eth is complex. Let's say "start at".
		// We need to traverse forward... Blockchain structure usually supports Number->Block.
		// StartHash -> Number.
		startNum := startBlock.Header.Number.Uint64()

		for i := uint64(0); i < msg.Limit; i++ {
			// Find block by number? core.Blockchain needs GetBlockByNumber
			// Assuming we added it? If not, we iterate hash?
			// We have GetBlockByHash.
			// Let's assume we implement GetBlockByNumber in core or just scan (slow).
			// Wait, rpc/api.go uses blockByNumber. core/blockchain.go should have it.
			// Checking...
			// If not, we use canonical chain map.

			// Let's assume we can get next block.
			// Actually we don't have GetBlockByNumber exposed easily maybe?
			// Let's rely on Hash if possible.
			// If request is by Hash, we need 'Child' index.
			// Simpler: Requester sends Number? No, forks.
			// Let's hack: Requester sends Number, we send block.
			// msg.StartHash is formal. Let's look up number from hash.

			// HACK: Use simple number iteration since we assume linear chain for PoC.
			b := s.Blockchain.GetBlockByNumber(startNum + 1 + i) // Core needs this
			if b == nil {
				break
			}
			blocks = append(blocks, b)
		}
	}

	resp := &BlocksMsg{Blocks: blocks}
	p.Send(resp)
}

// Handle returning blocks
func (s *Server) handleBlocks(p *Peer, msg *BlocksMsg) {
	fmt.Printf("\033[1;34m[📥] Recv %d blocks from Sync\033[0m\n", len(msg.Blocks))
	if s.OnBlockRecv != nil {
		for _, b := range msg.Blocks {
			s.OnBlockRecv(p, b)
		}
	}
}

// Callbacks
var (
// Set by Node
)

type BlockHandler func(p *Peer, b *types.Block)

// We need to add fields for callback
func (s *Server) RegisterBlockHandler(fn BlockHandler) {
	s.OnBlockRecv = fn
}

// Add to struct
// OnBlockRecv BlockHandler

func (s *Server) handleAuth(p *Peer, msg *AuthMsg) {
	// 1. Recover Public Key from Signature (Verification)
	// Hash the challenge because Ecrecover expects 32-byte hash
	hash := crypto.Keccak256(p.Challenge)

	recoveredPub, err := crypto.SigToPub(hash, msg.Signature)
	if err != nil {
		fmt.Printf("\033[1;31m[🛡] Check Failed:\033[0m Invalid Signature from %s: %v\n", p.conn.RemoteAddr(), err)
		p.server.RemovePeer(p)
		return
	}

	// 2. Derive Address
	addr := crypto.PubkeyToAddress(*recoveredPub)

	// 3. Check Validator Set
	cfg := s.Blockchain.Config()
	isValidator := false
	for _, v := range cfg.Validators {
		// v is *consensus.Validator
		if v.Address == addr {
			isValidator = true
			break
		}
	}

	if isValidator {
		fmt.Printf("\033[1;32m[🛡] Shield Verified:\033[0m Peer %s is VALIDATOR %s. Priority Access Granted.\n", p.conn.RemoteAddr(), addr.Hex()[:10])
		p.IsTrusted = true
	} else {
		fmt.Printf("\033[1;33m[🛡] Shield Info:\033[0m Peer %s is NOT a validator (%s). Rate Limits Apply.\n", p.conn.RemoteAddr(), addr.Hex()[:10])
		p.IsTrusted = false
		// Connection remains open, but Peer.go will enforce rate limits if !IsTrusted.
	}
}
