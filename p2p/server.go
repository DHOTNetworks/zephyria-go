package p2p

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"zephyria/core"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/quic-go/quic-go"
)

// Server manages the P2P network.
type Server struct {
	Config     ServerConfig
	Blockchain *core.Blockchain
	TxPool     *core.TxPool

	peers    map[*Peer]bool
	peerLock sync.RWMutex

	listener *quic.Listener
	quitCh   chan struct{}

	Discovery *Discovery
	Rotor     *Rotor
	Syncer    *Syncer

	// Callbacks
	OnBlockRecv    BlockHandler
	OnVoteRecv     VoteHandler
	OnSlashingRecv SlashingHandler

	// Internal Channels
	ingressCh chan *ingressBlock
	wg        sync.WaitGroup

	// Rotor Pool
	ShredPool map[common.Hash]map[uint64][]byte
	DonePool  map[common.Hash]bool // Track already reconstructed hashes
	shredLock sync.Mutex
}

func NewServer(cfg ServerConfig, bc *core.Blockchain, pool *core.TxPool) *Server {
	s := &Server{
		Config:     cfg,
		Blockchain: bc,
		TxPool:     pool,
		peers:      make(map[*Peer]bool),
		quitCh:     make(chan struct{}),
		ingressCh:  make(chan *ingressBlock, 16384), // Increased buffer to prevent stalls
		ShredPool:  make(map[common.Hash]map[uint64][]byte),
		DonePool:   make(map[common.Hash]bool),
	}

	var selfID NodeID
	if cfg.PrivateKey != nil {
		selfID = PubkeyToNodeID(&cfg.PrivateKey.PublicKey)
	} else {
		// Ephemeral ID
		key, _ := crypto.GenerateKey()
		selfID = PubkeyToNodeID(&key.PublicKey)
	}

	s.Discovery = NewDiscovery(selfID, cfg.DataDir)
	var err error
	s.Rotor, err = NewRotor()
	if err != nil {
		fmt.Printf("CRITICAL: Failed to initialize Rotor: %v\n", err)
	}
	s.Syncer = NewSyncer(s)

	return s
}

func (s *Server) Start() error {
	tlsConf, err := generateTLSConfig(s.Config.PrivateKey)
	if err != nil {
		return err
	}
	_ = tlsConf // Suppress unused error during debug phase

	// Simplified Listener Logic (Use provided address directly)
	addrStr := s.Config.ListenAddr

	udpAddr, err := net.ResolveUDPAddr("udp", addrStr)
	if err != nil {
		return err
	}

	udpConn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		return fmt.Errorf("failed to listen on %s: %v", addrStr, err)
	}

	// QUIC Listener
	ln, err := quic.Listen(udpConn, tlsConf, nil)
	if err != nil {
		udpConn.Close()
		return err
	}
	s.listener = ln
	fmt.Printf("\033[1;35m[🌐] QUIC P2P Server listening on %s (UDP) | ID: %s\033[0m\n", udpConn.LocalAddr().String(), hex.EncodeToString(s.Discovery.SelfID[:])[:8])
	fmt.Printf("\033[1;35m[🌐] QUIC P2P Server listening on %s | ID: %s\033[0m\n", s.Config.ListenAddr, hex.EncodeToString(s.Discovery.SelfID[:])[:8])

	s.Discovery.LoadPeers()

	for _, raw := range s.Config.Bootnodes {
		if node, err := ParseNode(raw); err == nil {
			s.Discovery.AddPeer(node)
			fmt.Printf("\033[1;33m[👢] Bootstrapping: Dialing %s...\033[0m\n", node.String())
			go s.DialNode(node)
		} else {
			go s.Dial(raw)
		}
	}

	go s.acceptLoop()
	go s.discoveryLoop()

	s.wg.Add(3)
	go s.ingressLoop()
	go s.syncLoop()
	go s.mempoolLoop()

	return nil
}

func (s *Server) Stop() {
	s.Discovery.SavePeers()
	close(s.quitCh)
	if s.listener != nil {
		s.listener.Close()
	}

	s.peerLock.Lock()
	peersToStop := make([]*Peer, 0, len(s.peers))
	for p := range s.peers {
		peersToStop = append(peersToStop, p)
	}
	s.peerLock.Unlock()

	for _, p := range peersToStop {
		p.Stop()
	}
	s.wg.Wait()
}

func (s *Server) Dial(addr string) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"zelius-p2p"},
	}
	// fmt.Printf("DEBUG: Dialing %s...\n", addr)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	// Bind to wildcard to allow OS to choose interface (IPv4/IPv6 compatible)
	udpAddr, err := net.ResolveUDPAddr("udp", ":0")
	if err != nil {
		fmt.Printf("ResolveUDPAddr failed: %v\n", err)
		return
	}
	udpConn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		fmt.Printf("ListenUDP failed: %v\n", err)
		return
	}

	destAddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		fmt.Printf("Resolve Dest Failed: %v\n", err)
		return
	}

	// fmt.Printf("DEBUG: Dialing QUIC -> %s\n", addr)
	conn, err := quic.Dial(ctx, udpConn, destAddr, tlsConf, &quic.Config{
		KeepAlivePeriod: 10 * time.Second,
		MaxIdleTimeout:  30 * time.Second,
	})
	if err != nil {
		// fmt.Printf("\033[1;31m[!] Dial Failed to %s: %v\033[0m\n", addr, err)
		return
	}
	// fmt.Printf("DEBUG: QUIC connection established to %s. Opening Stream...\n", addr)

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		fmt.Printf("\033[1;31m[!] Failed to open stream to %s: %v\033[0m\n", addr, err)
		conn.CloseWithError(0, "stream failed")
		return
	}
	// fmt.Printf("DEBUG: QUIC stream opened to %s\n", addr)

	netConn := &QuicConn{Stream: stream, Conn: conn}
	s.setupPeer(netConn, true)
}

func (s *Server) acceptLoop() {
	// fmt.Printf("DEBUG: Server acceptLoop started on %s\n", s.Config.ListenAddr)
	for {
		conn, err := s.listener.Accept(context.Background())
		if err != nil {
			select {
			case <-s.quitCh:
				return
			default:
				fmt.Printf("\033[1;31m[!] Accept Failed: %v\033[0m\n", err)
				continue
			}
		}
		// fmt.Printf("DEBUG: Server accepted incoming QUIC connection from %s\n", conn.RemoteAddr())

		go func(c *quic.Conn) {
			stream, err := c.AcceptStream(context.Background())
			if err != nil {
				fmt.Printf("\033[1;31m[!] AcceptStream Failed: %v\033[0m\n", err)
				return
			}
			netConn := &QuicConn{Stream: stream, Conn: c}
			s.setupPeer(netConn, false)
		}(conn)
	}
}

func (s *Server) setupPeer(conn net.Conn, outbound bool) {
	// fmt.Printf("DEBUG: setupPeer called for %s (outbound: %v)\n", conn.RemoteAddr(), outbound)
	p := NewPeer(conn, s, outbound)
	s.peerLock.Lock()
	s.peers[p] = true
	s.peerLock.Unlock()

	// Syncer registration moved to handleStatus (Post-Handshake)
	// s.Syncer.RegisterPeer(p)
	p.Start()

	cfg := s.Blockchain.Config()
	current := s.Blockchain.CurrentBlock()

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
	if !s.peers[p] {
		s.peerLock.Unlock()
		return
	}
	delete(s.peers, p)
	s.peerLock.Unlock()

	s.Syncer.UnregisterPeer(p)
	p.Stop()
	fmt.Printf("\033[1;31m[-] Peer Disconnected:\033[0m %s\n", p.conn.RemoteAddr())
}

func (s *Server) PeerCount() int {
	s.peerLock.RLock()
	defer s.peerLock.RUnlock()
	return len(s.peers)
}

func (s *Server) Self() *Node {
	host, portStr, _ := net.SplitHostPort(s.Config.ListenAddr)
	port, _ := strconv.Atoi(portStr)
	ip := net.ParseIP(host)

	// If listening on all interfaces, advertise reliable local IP (e.g. for devnet)
	if ip == nil || ip.IsUnspecified() {
		// Fallback for 0.0.0.0 -> 127.0.0.1 (For local dev)
		// in production this should be the public IP
		ip = net.ParseIP("127.0.0.1")
	}

	return &Node{
		ID:   s.Discovery.SelfID,
		IP:   ip,
		Port: uint16(port),
	}
}

func (s *Server) ingressLoop() {
	defer s.wg.Done()
	for {
		select {
		case <-s.quitCh:
			return
		case msg := <-s.ingressCh:
			if s.OnBlockRecv != nil {
				s.OnBlockRecv(msg.Peer, msg.Block)
			}
		}
	}
}

func (s *Server) syncLoop() {
	defer s.wg.Done()
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-s.quitCh:
			return
		case <-ticker.C:
			current := s.Blockchain.CurrentBlock().Header.Number.Uint64()
			var bestPeer *Peer
			var bestHeight uint64

			s.peerLock.RLock()
			for p := range s.peers {
				if p.HeadNumber > current && p.HeadNumber > bestHeight {
					bestHeight = p.HeadNumber
					bestPeer = p
				}
			}
			s.peerLock.RUnlock()

			if bestPeer != nil && !s.Syncer.IsSyncing() {
				s.Syncer.CheckAndStart(bestPeer)
			}
		}
	}
}

func (s *Server) RegisterBlockHandler(fn BlockHandler) {
	s.OnBlockRecv = fn
}

func (s *Server) RegisterVoteHandler(fn VoteHandler) {
	s.OnVoteRecv = fn
}

func (s *Server) RegisterSlashingHandler(fn SlashingHandler) {
	s.OnSlashingRecv = fn
}

// Broadcast sends a message to all connected peers.
func (s *Server) Broadcast(code uint64, msg interface{}) {
	s.peerLock.RLock()
	defer s.peerLock.RUnlock()

	for p := range s.peers {
		if !p.HandshakeComplete {
			continue
		}
		p.Send(msg)
	}
}

func (s *Server) discoveryLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-s.quitCh:
			return
		case <-ticker.C:
			if s.PeerCount() < 10 {
				peers := s.Discovery.GetRandomPeers(5)
				for _, p := range peers {
					go s.DialNode(p)
				}
			}
		}
	}
}

func (s *Server) DialNode(n *Node) {
	ipStr := n.IP.String()
	if strings.Contains(ipStr, ":") {
		ipStr = fmt.Sprintf("[%s]", ipStr)
	}
	addr := fmt.Sprintf("%s:%d", ipStr, n.Port)
	s.Dial(addr)
}

func generateTLSConfig(_ *ecdsa.PrivateKey) (*tls.Config, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}

	template := x509.Certificate{
		SerialNumber:          big.NewInt(1),
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}

	keyBytes, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, err
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes})
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: derBytes})

	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}

	return &tls.Config{
		Certificates: []tls.Certificate{tlsCert},
		NextProtos:   []string{"zelius-p2p"},
	}, nil
}

func (s *Server) mempoolLoop() {
	defer s.wg.Done()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-s.quitCh:
			return
		case <-ticker.C:
			if s.TxPool == nil {
				continue
			}
			pending := s.TxPool.Pending()
			if len(pending) == 0 {
				continue
			}
			hashes := make([]common.Hash, len(pending))
			for i, tx := range pending {
				hashes[i] = tx.Hash()
			}
			inv := &TxsInvMsg{Hashes: hashes}
			s.peerLock.RLock()
			for p := range s.peers {
				p.Send(inv)
			}
			s.peerLock.RUnlock()
		}
	}
}
