package p2p

import (
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/rlp"
)

// Peer represents a connected remote node.
type Peer struct {
	conn     net.Conn
	server   *Server
	outbound bool // true if we initiated the connection

	sendCh chan interface{} // Channel for outgoing messages (structs)
	quitCh chan struct{}
	wg     sync.WaitGroup

	// State
	HeadHash   string // Hex or concrete? Helper to track peer's known state.
	HeadNumber uint64

	// Zelius Shield State
	Challenge []byte // The challenge we sent to them
	IsTrusted bool   // True if they are a verified validator
}

func NewPeer(conn net.Conn, server *Server, outbound bool) *Peer {
	return &Peer{
		conn:     conn,
		server:   server,
		outbound: outbound,
		sendCh:   make(chan interface{}, 100),
		quitCh:   make(chan struct{}),
	}
}

func (p *Peer) Start() {
	p.wg.Add(2)
	go p.readLoop()
	go p.writeLoop()
}

func (p *Peer) Stop() {
	close(p.quitCh)
	p.conn.Close()
	p.wg.Wait()
}

func (p *Peer) Send(msg interface{}) {
	select {
	case p.sendCh <- msg:
	case <-p.quitCh:
	default:
		// buffer full, drop? or block? For PoC drop is safer to avoid deadlock if peer stalls.
		fmt.Println("Peer send buffer full, dropping message")
	}
}

func (p *Peer) readLoop() {
	defer p.wg.Done()
	// Using RLP stream from connection
	// Need to wrap net.Conn in limited reader? RLP Stream handles buffering.
	// But standard direct RLP decoding from connection works if formatted correctly.
	// Usually wire protocol has [Size][MsgCode][Payload].
	// For PoC, we'll rely on RLP streaming decoder which frames by object.
	// Format: RLP( [MsgCode, Payload] ) ?
	// Or just stream of RLP objects.
	// Simpler for PoC: Use a struct envelope:
	// type Envelope struct { Code uint, Payload []byte } - generic RLP?
	// Actually go-ethereum/rlp decoding stream is robust.
	// Let's define the wire format as: RLP(Envelope{Code, Interface})?
	// Interface is tricky in RLP.
	// Let's do: Packet = [Code, RLP(Payload)]
	// Packet = [Code, RLP(Payload)]
	// Payload is already RLP encoded bytes in wire format?
	// Envelope struct { Code uint64, Payload []byte }

	// go-ethereum/rlp Decode(reader, &val) handles the stream.

	// Rate Limiter: Max 100 msgs/sec
	lastMsgTime := time.Now()
	msgsThisSec := 0

	for {
		select {
		case <-p.quitCh:
			return
		default:
		}

		// Set read deadline
		p.conn.SetReadDeadline(time.Now().Add(60 * time.Second)) // ping/pong needed for real prod

		// Decode envelope
		var envelope struct {
			Code    uint64
			Payload []byte
		}
		// RLP Decode from stream
		if err := rlp.Decode(p.conn, &envelope); err != nil {
			// Log usually verbose, keep specific error check
			// fmt.Printf("Peer read error: %v\n", err)
			p.server.RemovePeer(p)
			return
		}

		// Zelius Shield: Rate Limiting
		now := time.Now()
		if now.Sub(lastMsgTime) > time.Second {
			lastMsgTime = now
			msgsThisSec = 0
		}
		msgsThisSec++

		limit := 100
		if p.IsTrusted {
			limit = 10000 // High limit for validators
		}

		if msgsThisSec > limit {
			fmt.Printf("\033[1;31m[🛡] Shield Alert:\033[0m Peer %s exceeded rate limit (%d/s). Disconnecting.\n", p.conn.RemoteAddr(), limit)
			p.server.RemovePeer(p)
			return
		}

		// Enforce Max Message Size (Hardcoded Security Limit: 10MB)
		if len(envelope.Payload) > 10*1024*1024 {
			fmt.Printf("SECURITY ALERT: Peer sent oversized message (%d bytes). Disconnecting.\n", len(envelope.Payload))
			p.server.RemovePeer(p)
			return
		}

		// Handle
		p.server.handleMessage(p, envelope.Code, envelope.Payload)
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
			default:
				fmt.Printf("Unknown message type: %T\n", msg)
				continue
			}

			// Encode payload
			payload, err := rlp.EncodeToBytes(msg)
			if err != nil {
				fmt.Println("Encode error:", err)
				continue
			}

			// Wrap in envelope
			envelope := struct {
				Code    uint64
				Payload []byte
			}{Code: code, Payload: payload}

			// Send
			if err := rlp.Encode(p.conn, envelope); err != nil {
				fmt.Println("Peer write error:", err)
				p.server.RemovePeer(p)
				return
			}
		}
	}
}
