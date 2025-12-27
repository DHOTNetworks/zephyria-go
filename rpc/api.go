package rpc

import (
	"github.com/ethereum/go-ethereum/rpc"
)

// NewServer creates a new RPC server.
func NewServer() *rpc.Server {
	return rpc.NewServer()
}
