package main

import (
	"bufio"
	"crypto/ecdsa"
	"flag"
	"fmt"
	"math/big"
	"net"
	"os"
	"strings"

	"zephyria/core"
	"zephyria/node"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

func main() {
	// Flags
	var (
		dataDirFlag = flag.String("datadir", "", "Path to data directory")
		portFlag    = flag.Int("port", 0, "Base port for P2P (HTTP=port, WS=port+1) or auto-discovery base")
		networkFlag = flag.String("network", "devnet", "Network name (devnet, testnet, mainnet)")
		mineFlag    = flag.Bool("mine", false, "Start mining immediately")
		keyFlag     = flag.String("key", "", "Private key in hex (for validator)")
		ipcFlag     = flag.String("ipcpath", "", "Path to IPC socket file")
	)
	flag.Parse()

	fmt.Println("🚀 Starting Zephyria Interactive Node...")

	// 1. Configure Node
	netType := *networkFlag

	var privKey *ecdsa.PrivateKey
	if *keyFlag != "" {
		kHex := strings.TrimPrefix(*keyFlag, "0x")
		k, err := crypto.HexToECDSA(kHex)
		if err != nil {
			fmt.Printf("❌ Invalid key provided: %v\n", err)
			os.Exit(1)
		}
		privKey = k
	} else {
		// Default logic
		if netType == core.Mainnet || netType == core.Testnet {
			// Require key for production? For now warn and use dev key or generated
			fmt.Println("⚠️  WARNING: No key provided for non-dev network. Using Default Dev Key (UNSAFE).")
		}
		privKey, _ = crypto.HexToECDSA(core.DefaultDevKey)
		fmt.Printf("🔑 Loaded Default Dev Key: %s\n", crypto.PubkeyToAddress(privKey.PublicKey).Hex())
	}

	// Dynamic Port Resolution
	var baseP2P, httpPort, wsPort int

	if *portFlag > 0 {
		// If explicit port set, try to adhere to it
		baseP2P = *portFlag  // Use as P2P match
		httpPort = *portFlag // Use same for HTTP? Convention usually splits them.
		// Previous logic: P2P=30303, HTTP=8545.
		// If user says --port 8545, they probably mean HTTP.
		// Let's adopt Geth style: --port (P2P), --http.port (HTTP).
		// But for simplicity here, let's say --port sets HTTP, and we derive others?
		// Or --port sets P2P, and HTTP is +offset?
		// The prompt implementation had: p (P2P), http=p-30303+8545.
		// Let's stick to simple or standard:
		// If port supplied, use it for HTTP (RPC), and +1 for WS, and random/default for P2P?
		// Actually, usually --port is P2P in Geth. --http is HTTP.
		// Since I don't have separate flags, I'll interpret --port as HTTP port (since that's what user interacts with mostly for Remix/Metamask).
		httpPort = *portFlag
		wsPort = httpPort + 1
		baseP2P = httpPort + 21758 // (8545 + 21758 = 30303) roughly.
		// Or just find available for P2P.
		baseP2P = findAvailablePort(30303)
	} else {
		// Strict Defaults for Dev Reliability
		httpPort = 8545 // Metamask default
		wsPort = 8546
		baseP2P = 30303
	}

	// Datadir
	dataDir := *dataDirFlag
	if dataDir == "" {
		// Default
		dataDir = "zephyria-chaindata"
	}
	// Ensure absolute or relative is respected? logic handles it.

	// IPC Default
	ipcPath := *ipcFlag
	if ipcPath == "" {
		// Default to datadir/zephyria.ipc
		// We need to resolve datadir first if relative to ensure correct placement,
		// but standard is inside datadir.
		ipcPath = dataDir + "/zephyria.ipc"
	}

	cfg := &node.Config{
		DataDir:      dataDir,
		P2PPort:      baseP2P,
		HTTPPort:     httpPort,
		WSPort:       wsPort,
		IPCPath:      ipcPath,
		Network:      netType,
		ValidatorKey: privKey,
		Bootnodes:    []string{},
	}

	n := node.New(cfg)

	if err := n.Start(); err != nil {
		fmt.Printf("Failed to start node: %v\n", err)
		os.Exit(1)
	}

	if *mineFlag {
		n.StartMining()
		fmt.Println("⛏️  Mining Started")
	}

	fmt.Printf("\n✅ Node Running at: %s\n", dataDir)
	fmt.Printf("Endpoints: HTTP=:%d | WS=:%d | P2P=:%d\n", cfg.HTTPPort, cfg.WSPort, cfg.P2PPort)
	fmt.Println("Commands: info, addkey <hex>, stake <amt> <addr>, unstake <addr>, exit")

	// 2. Interactive Loop (non-blocking if mining, but scanner blocks main thread which is fine)
	scanner := bufio.NewScanner(os.Stdin)
	for {
		fmt.Print("> ")
		if !scanner.Scan() {
			break
		}
		line := scanner.Text()
		parts := strings.Fields(line)
		if len(parts) == 0 {
			continue
		}

		cmd := parts[0]
		switch cmd {
		case "exit", "quit":
			fmt.Println("Shutting down...")
			n.Stop()
			return
		case "info":
			bc := n.Blockchain()
			head := bc.CurrentBlock().Header
			fmt.Printf("Block Height: %d\n", head.Number.Uint64())
			fmt.Printf("Current Hash: %s\n", head.Hash().Hex())
			fmt.Printf("State Root:   %s\n", head.VerkleRoot.Hex())

		case "balance":
			if len(parts) < 2 {
				fmt.Println("Usage: balance <address>")
				continue
			}
			addrStr := parts[1]
			if !common.IsHexAddress(addrStr) {
				fmt.Println("Invalid address")
				continue
			}
			addr := common.HexToAddress(addrStr)
			bal := n.GetBalance(addr)
			fmt.Printf("Balance of %s: %s ZEE\n", addr.Hex(), bal.String())

		case "peers":
			addr, count := n.P2PInfo()
			fmt.Printf("P2P Listener: %s\n", addr)
			fmt.Printf("Connected Peers: %d\n", count)

		case "addpeer":
			if len(parts) < 2 {
				fmt.Println("Usage: addpeer <ip:port>") // Raw TCP for PoC
				continue
			}
			n.AddPeer(parts[1])
			fmt.Println("Dialing peer...")

		case "addkey":
			if len(parts) < 2 {
				fmt.Println("Usage: addkey <private_key_hex>")
				continue
			}
			kHex := parts[1]
			kHex = strings.TrimPrefix(kHex, "0x")
			k, err := crypto.HexToECDSA(kHex)
			if err != nil {
				fmt.Printf("Invalid key: %v\n", err)
				continue
			}
			n.AddKey(k)
			addr := crypto.PubkeyToAddress(k.PublicKey)
			fmt.Printf("Added account: %s\n", addr.Hex())

		case "stake":
			if len(parts) < 3 {
				fmt.Println("Usage: stake <amount> <address>")
				continue
			}
			amtStr := parts[1]
			addrStr := parts[2]

			amt, ok := new(big.Int).SetString(amtStr, 10)
			if !ok {
				fmt.Println("Invalid amount")
				continue
			}
			if !common.IsHexAddress(addrStr) {
				fmt.Println("Invalid address")
				continue
			}
			addr := common.HexToAddress(addrStr)

			err := n.SendStakeTx(amt, addr)
			if err != nil {
				fmt.Printf("Error: %v\n", err)
			} else {
				fmt.Println("Stake Tx Submitted.")
			}

		case "unstake":
			if len(parts) < 2 {
				fmt.Println("Usage: unstake <address>")
				continue
			}
			addrStr := parts[1]
			if !common.IsHexAddress(addrStr) {
				fmt.Println("Invalid address")
				continue
			}
			addr := common.HexToAddress(addrStr)

			err := n.SendUnstakeTx(addr)
			if err != nil {
				fmt.Printf("Error: %v\n", err)
			} else {
				fmt.Println("Unstake Tx Submitted.")
			}

		default:
			fmt.Println("Unknown command.")
		}
	}
}

// findAvailablePort checks if a port is in use and increments until availability.
func findAvailablePort(start int) int {
	for port := start; port < start+100; port++ {
		ln, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
		if err == nil {
			ln.Close()
			return port
		}
	}
	return start // Fallback
}
