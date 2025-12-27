package node

import "crypto/ecdsa"

// Config defines the configuration for the Zephyria node.
type Config struct {
	Network      string
	DataDir      string
	HTTPPort     int
	ValidatorKey *ecdsa.PrivateKey

	// P2P
	P2PPort   int
	WSPort    int
	IPCPath   string // Path to IPC socket file
	Bootnodes []string
}

// DefaultConfig returns a standard configuration.
func DefaultConfig() *Config {
	return &Config{
		Network:  "devnet",
		DataDir:  "zephyria-chaindata",
		HTTPPort: 8545,
		P2PPort:  30303,
	}
}
