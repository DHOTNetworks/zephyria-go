package p2p

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/rlp"
	"golang.org/x/time/rate"
)

// Protocol messages are prefixed with a 1-byte code.

// Peer represents a connected remote node.
type Peer struct {
	conn     net.Conn
	server   *Server
	outbound bool // true if we initiated the connection

	sendCh   chan interface{} // Channel for outgoing messages (structs)
	quitCh   chan struct{}
	wg       sync.WaitGroup
	stopOnce sync.Once

	// State
	HeadHash   string // Hex or concrete? Helper to track peer's known state.
	HeadNumber uint64

	// Zelius Shield State
	Challenge         []byte // The challenge we sent to them
	IsTrusted         bool   // True if they are a verified validator
	HandshakeComplete bool   // True if StatusMsg verified

	// Rate Limiters
	blockLimiter *rate.Limiter
	txLimiter    *rate.Limiter
	voteLimiter  *rate.Limiter
}

func NewPeer(conn net.Conn, server *Server, outbound bool) *Peer {
	return &Peer{
		conn:     conn,
		server:   server,
		outbound: outbound,
		sendCh:   make(chan interface{}, 100),
		quitCh:   make(chan struct{}),

		// Rate Limits (per second, burst)
		blockLimiter: rate.NewLimiter(10, 20),   // 10 blocks/sec (plenty for high tps)
		txLimiter:    rate.NewLimiter(100, 200), // 100 txs/sec
		voteLimiter:  rate.NewLimiter(50, 100),  // 50 votes/sec
	}
}

func (p *Peer) Start() {
	p.wg.Add(3)
	go p.readLoop()
	go p.writeLoop()
	go p.pingLoop()
}

func (p *Peer) Stop() {
	p.stopOnce.Do(func() {
		close(p.quitCh)
		p.conn.Close()
	})
	// Do NOT wait here. It causes deadlock if called from readLoop/writeLoop.
	// The goroutines will exit naturally when conn closes or quitCh closes.
}

func (p *Peer) Send(msg interface{}) {
	select {
	case p.sendCh <- msg:
	case <-p.quitCh:
	default:
		// buffer full, drop immediately
	}
}

func (p *Peer) readLoop() {
	defer p.wg.Done()
	lastMsgTime := time.Now()
	msgsThisSec := 0

	for {
		select {
		case <-p.quitCh:
			return
		default:
		}

		p.conn.SetReadDeadline(time.Now().Add(60 * time.Second))

		// 1. Read Size (4 bytes)
		var sizeBuf [4]byte
		if _, err := io.ReadFull(p.conn, sizeBuf[:]); err != nil {
			p.server.RemovePeer(p)
			return
		}
		size := binary.BigEndian.Uint32(sizeBuf[:])

		// 2. Read Frame (Code + Payload)
		// Limit size to prevent DOS (e.g., 10MB)
		if size > 10*1024*1024 {
			fmt.Printf("Message too large: %d\n", size)
			p.server.RemovePeer(p)
			return
		}

		frame := make([]byte, size)
		if _, err := io.ReadFull(p.conn, frame); err != nil {
			p.server.RemovePeer(p)
			return
		}

		code := uint64(frame[0])
		payload := frame[1:]

		// Rate Limiting
		now := time.Now()
		if now.Sub(lastMsgTime) > time.Second {
			lastMsgTime = now
			msgsThisSec = 0
		}
		msgsThisSec++
		limit := 500
		if p.IsTrusted {
			limit = 10000
		}
		if msgsThisSec > limit {
			fmt.Printf("\033[1;31m[🛡] Shield Alert:\033[0m Peer %s exceeded rate limit. Disconnecting.\n", p.conn.RemoteAddr())
			p.server.RemovePeer(p)
			return
		}

		// 3. Handle via stream (use bytes.Reader)
		p.server.handleMessageStream(p, code, bytes.NewReader(payload))
	}
}

func (p *Peer) writeLoop() {
	defer p.wg.Done()
	for {
		select {
		case <-p.quitCh:
			return
		case msg := <-p.sendCh:
			p.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))

			// Determine code
			var code uint64
			switch msg.(type) {
			case *StatusMsg:
				code = MsgStatus
			case *NewBlockMsg:
				code = MsgNewBlock
			case *GetBlocksMsg:
				code = MsgGetBlocks
			case *BlocksMsg:
				code = MsgBlocks
			case *AuthMsg:
				code = MsgAuth
			case *TxMsg:
				code = MsgTx
			case *GetSnapMsg:
				code = MsgGetSnap
			case *SnapDataMsg:
				code = MsgSnapData
			case *GetPeersMsg:
				code = MsgGetPeers
			case *PeersMsg:
				code = MsgPeers
			case *VoteMsg:
				code = MsgVote
			case *BlockShredMsg:
				code = MsgBlockShred
			case *GetHeadersMsg:
				code = MsgGetHeaders
			case *HeadersMsg:
				code = MsgHeaders
			case *GetBodiesMsg:
				code = MsgGetBodies
			case *BodiesMsg:
				code = MsgBodies
			case *AnnouncementMsg:
				code = MsgAnnouncement
			case *PingMsg:
				code = MsgPing
			case *PongMsg:
				code = MsgPong
			case *TxsInvMsg:
				code = MsgTxsInv
			case *GetTxsMsg:
				code = MsgGetTxs
			case *SlashingMsg:
				code = MsgSlashing
			default:
				fmt.Printf("Unknown message type: %T\n", msg)
				continue
			}

			// 1. Encode Payload
			payload, err := rlp.EncodeToBytes(msg)
			if err != nil {
				fmt.Printf("ERROR: Encoding failed: %v\n", err)
				continue
			}

			// 2. Prepare Frame: [Size (4)] + [Code (1)] + [Payload]
			size := uint32(1 + len(payload))
			buf := new(bytes.Buffer)
			binary.Write(buf, binary.BigEndian, size)
			buf.WriteByte(byte(code))
			buf.Write(payload)

			// 3. Write All
			if _, err := p.conn.Write(buf.Bytes()); err != nil {
				// Check if we are closing (Graceful shutdown race)
				select {
				case <-p.quitCh:
					return // Ignore error, we are stopping
				default:
				}

				if err.Error() == "write on closed stream 0" {
					return
				}

				fmt.Printf("ERROR: Peer %s write error: %v\n", p.conn.RemoteAddr(), err)
				p.server.RemovePeer(p)
				return
			}
			// fmt.Printf("TRACE: Peer %s sent message code: %d successfully\n", p.conn.RemoteAddr(), code)
		}
	}
}

func (p *Peer) pingLoop() {
	defer p.wg.Done()
	ticker := time.NewTicker(20 * time.Second) // KeepAlive every 20s (Timeout is 60s)
	defer ticker.Stop()

	for {
		select {
		case <-p.quitCh:
			return
		case <-ticker.C:
			p.Send(&PingMsg{})
		}
	}
}
func (p *Peer) Addr() string {
	if p.conn == nil {
		return "unknown"
	}
	return p.conn.RemoteAddr().String()
}
