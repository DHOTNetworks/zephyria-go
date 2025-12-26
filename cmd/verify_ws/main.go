package main

import (
	"context"
	"fmt"
	"log"

	"github.com/ethereum/go-ethereum/rpc"
)

func main() {
	// Connect to Node 1 WS
	client, err := rpc.Dial("ws://localhost:8546")
	if err != nil {
		log.Fatalf("Failed to connect to WS: %v", err)
	}
	defer client.Close()

	fmt.Println("Connected to WebSocket :8546")

	// Call eth_blockNumber
	var result string
	err = client.CallContext(context.Background(), &result, "eth_blockNumber")
	if err != nil {
		log.Fatalf("RPC Call failed: %v", err)
	}

	fmt.Printf("Current Block Number (Hex): %s\n", result)
	fmt.Println("✅ WebSocket RPC Test Passed!")
}
