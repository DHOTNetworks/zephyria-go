package p2p

import (
	"crypto/ecdsa"
	"net"

	"zephyria/types"

	"github.com/quic-go/quic-go"
)

// QuicConn adapts *quic.Stream to net.Conn
type QuicConn struct {
	*quic.Stream
	Conn *quic.Conn
}

func (q *QuicConn) LocalAddr() net.Addr {
	return q.Conn.LocalAddr()
}

func (q *QuicConn) RemoteAddr() net.Addr {
	return q.Conn.RemoteAddr()
}

func (q *QuicConn) Close() error {
	q.Stream.Close()
	return nil
}

type ingressBlock struct {
	Peer  *Peer
	Block *types.Block
}

type BlockHandler func(p *Peer, b *types.Block)
type VoteHandler func(p *Peer, v *types.Vote)
type SlashingHandler func(p *Peer, s *types.SlashingProof) error

type ServerConfig struct {
	ListenAddr string
	Bootnodes  []string
	PrivateKey *ecdsa.PrivateKey
	DataDir    string
}
