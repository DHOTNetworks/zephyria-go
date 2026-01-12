package p2p

import (
	"crypto/ecdsa"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum/crypto"
)

// NodeID is a unique identifier for a node (Public Key).
// For simplicity in this PoC, we use the 64-byte uncompressed pubkey (without 0x04 prefix)
// or just the raw bytes. Geth uses 64 bytes.
type NodeID [64]byte

// Node represents a peer in the network.
type Node struct {
	ID   NodeID
	IP   net.IP
	Port uint16 // QUIC/TCP Port
}

// String returns the enode URL representation.
// format: enode://<hex_id>@<ip>:<port>
func (n *Node) String() string {
	ipStr := n.IP.String()
	if strings.Contains(ipStr, ":") {
		ipStr = fmt.Sprintf("[%s]", ipStr)
	}
	return fmt.Sprintf("enode://%s@%s:%d", hex.EncodeToString(n.ID[:]), ipStr, n.Port)
}

// ParseNode parses an enode URL.
func ParseNode(rawURL string) (*Node, error) {
	if rawURL == "" {
		return nil, errors.New("empty URL")
	}

	// Helper: url.Parse requires scheme
	if !strings.HasPrefix(rawURL, "enode://") {
		return nil, errors.New("invalid scheme, expected enode://")
	}

	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}

	// Host is ip:port
	host, portStr, err := net.SplitHostPort(u.Host)
	if err != nil {
		return nil, fmt.Errorf("invalid host: %v", err)
	}

	port, err := strconv.Atoi(portStr)
	if err != nil {
		return nil, fmt.Errorf("invalid port: %v", err)
	}

	ip := net.ParseIP(host)
	if ip == nil {
		return nil, errors.New("invalid IP address")
	}

	// User (pubkey)
	pubKeyHex := u.User.Username()
	if pubKeyHex == "" {
		// Sometimes it's in the host part if no @? url.Parse handles user@host
		return nil, errors.New("missing node ID")
	}

	pubBytes, err := hex.DecodeString(pubKeyHex)
	if err != nil {
		return nil, fmt.Errorf("invalid node ID hex: %v", err)
	}

	if len(pubBytes) != 64 {
		return nil, fmt.Errorf("invalid node ID length: want 64, got %d", len(pubBytes))
	}

	var id NodeID
	copy(id[:], pubBytes)

	return &Node{
		ID:   id,
		IP:   ip,
		Port: uint16(port),
	}, nil
}

// PubkeyToNodeID converts an ECDSA public key to a NodeID.
func PubkeyToNodeID(pub *ecdsa.PublicKey) NodeID {
	// crypto.FromECDSAPub returns 65 bytes (0x04 + X + Y)
	// We want 64 bytes (X + Y)
	b := crypto.FromECDSAPub(pub)
	var id NodeID
	copy(id[:], b[1:])
	return id
}

// NodeIDToPubkey converts a NodeID back to ECDSA public key.
func NodeIDToPubkey(id NodeID) (*ecdsa.PublicKey, error) {
	// Prepend 0x04
	b := make([]byte, 65)
	b[0] = 4
	copy(b[1:], id[:])
	return crypto.UnmarshalPubkey(b)
}

// HexToNodeID parses a hex string to a NodeID.
func HexToNodeID(h string) (NodeID, error) {
	var id NodeID
	b, err := hex.DecodeString(h)
	if err != nil {
		return id, err
	}
	if len(b) != 64 {
		return id, errors.New("invalid length")
	}
	copy(id[:], b)
	return id, nil
}
