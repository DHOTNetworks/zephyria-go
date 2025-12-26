package main

import (
	"fmt"
	"math/big"
	"os"
	"os/signal"
	"syscall"
	"time"

	"zephyria/core"
	"zephyria/node"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

// 4 Validator Keys (Deterministic for simulation)
var valKeys = []string{
	"ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", // Val 0 (Anvil/Foundry default test keys)
	"59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d", // Val 1
	"5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a", // Val 2
	"7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6", // Val 3
}

func main() {
	fmt.Println("🚀 Starting Zephyria Multi-Node Simulation (Zelius Consensus)")

	// 1. Setup Network Config (Genesis with 4 validators)
	validators := make([]string, 4)
	for i, k := range valKeys {
		key, _ := crypto.HexToECDSA(k)
		addr := crypto.PubkeyToAddress(key.PublicKey).Hex()
		validators[i] = addr
		fmt.Printf("[Init] Validator %d: %s\n", i, addr)
	}

	// 2. Cleanup Data Dirs
	for i := 0; i < 4; i++ {
		os.RemoveAll(fmt.Sprintf("tmp/sim_node_%d", i))
	}

	// 3. Start Nodes
	nodes := make([]*node.Node, 4)
	for i := 0; i < 4; i++ {
		key, _ := crypto.HexToECDSA(valKeys[i])

		cfg := &node.Config{
			DataDir:      fmt.Sprintf("tmp/sim_node_%d", i),
			P2PPort:      30300 + i,
			HTTPPort:     8500 + i,
			Network:      core.Simulation,
			ValidatorKey: key,
			Bootnodes:    []string{}, // We will manually peer them
		}

		n := node.New(cfg)
		if err := n.Start(); err != nil {
			panic(fmt.Sprintf("Node %d failed to start: %v", i, err))
		}
		n.StartMining()
		nodes[i] = n
		fmt.Printf("[Start] Node %d listening on :%d (P2P) / :%d (RPC)\n", i, cfg.P2PPort, cfg.HTTPPort)
	}

	// 4. Peering (Mesh)
	time.Sleep(2 * time.Second) // Let them start
	fmt.Println("🔗 Connecting Mesh...")
	// Node 0 connects to all. Node 1 connects to all...
	// Full Mesh: Everyone dials everyone (simpler for small N)
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			if i == j {
				continue
			}
			// Dial
			targetPort := 30300 + j
			addr := fmt.Sprintf("127.0.0.1:%d", targetPort)
			nodes[i].DialPeer(addr)
		}
	}

	// 5. Wait for Consensus Handshake
	time.Sleep(5 * time.Second)
	fmt.Println("✅ Network Stabilized. Sending Traffic...")

	// 6. Traffic Generation (Send to Node 0, verified by all)
	// Send 1000 Txs from Val 0 to Random
	signer := ethtypes.LatestSigner(core.GetNetworkConfig(core.Simulation).ChainConfig())
	val0Key, _ := crypto.HexToECDSA(valKeys[0])

	go func() {
		for i := 0; i < 100; i++ {
			nonce := uint64(i) // Simple nonce tracking (assuming fresh state)
			// Note: Use state nonce in real code, but for fast blast we assume 0..N
			// Actually, we should ask node for nonce ideally.
			// For simulation speed, we track locally.

			tx := ethtypes.NewTransaction(nonce, common.HexToAddress("0xdeadbeef"), big.NewInt(100), 21000, big.NewInt(100), nil)
			signedTx, _ := ethtypes.SignTx(tx, signer, val0Key)

			nodes[0].SubmitTx(signedTx)

			// Distributed load? Send some to Node 1 too
			if i%2 == 0 {
				nodes[1].SubmitTx(signedTx) // Sending same tx to multiple is fine, gossip handles it
			}

			time.Sleep(10 * time.Millisecond)
		}
	}()

	// 7. Monitor Loop
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-sigCh:
			fmt.Println("\nStopping Simulation...")
			for _, n := range nodes {
				n.Stop()
			}
			return
		case <-ticker.C:
			// Check heights
			h0 := nodes[0].Blockchain().CurrentBlock().Header.Number.Uint64()
			h1 := nodes[1].Blockchain().CurrentBlock().Header.Number.Uint64()
			h2 := nodes[2].Blockchain().CurrentBlock().Header.Number.Uint64()
			h3 := nodes[3].Blockchain().CurrentBlock().Header.Number.Uint64()

			fmt.Printf("[Status] Heights: [%d %d %d %d]\n", h0, h1, h2, h3)

			if h0 > 20 && h0 == h1 && h1 == h2 && h2 == h3 {
				fmt.Println("🎉 SUCCESS: All nodes synchronized past block 20!")
				// Exit automatically after success for CI/Test feel
				for _, n := range nodes {
					n.Stop()
				}
				return
			}
		}
	}
}
