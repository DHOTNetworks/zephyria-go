package node

import "crypto/ecdsa"

// Config defines the configuration for the Zephyria node.
type Config struct {
	Network      string
	DataDir      string
	HTTPPort     int
	HTTPHost     string
	HTTPEnabled  bool
	ValidatorKey *ecdsa.PrivateKey

	// P2P
	P2PPort   int
	WSPort    int
	WSHost    string
	WSEnabled bool
	IPCPath   string // Path to IPC socket file
	Bootnodes []string
}

// DefaultConfig returns a standard configuration.
func DefaultConfig() *Config {
	return &Config{
		Network:     "devnet",
		DataDir:     "zephyria-chaindata",
		HTTPPort:    8545,
		HTTPHost:    "0.0.0.0", // Listen on all interfaces (Fixes localhost ipv6 issues)
		HTTPEnabled: true,
		P2PPort:     30303,
		WSPort:      8546,
		WSHost:      "0.0.0.0",
		WSEnabled:   false,
	}
}
