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
		dataDirFlag   = flag.String("datadir", "", "Path to data directory")
		portFlag      = flag.Int("port", 30303, "Network listening port")
		networkFlag   = flag.String("network", "devnet", "Network name (devnet, testnet, mainnet)")
		mineFlag      = flag.Bool("mine", false, "Start mining immediately")
		keyFlag       = flag.String("key", "", "Private key in hex (for validator)")
		ipcFlag       = flag.String("ipcpath", "", "Path to IPC socket file")
		bootnodesFlag = flag.String("bootnodes", "", "Comma separated enode URLs for P2P discovery bootstrap")

		// HTTP
		httpFlag     = flag.Bool("http", true, "Enable the HTTP-RPC server")
		httpAddrFlag = flag.String("http.addr", "0.0.0.0", "HTTP-RPC server listening interface")
		httpPortFlag = flag.Int("http.port", 8545, "HTTP-RPC server listening port")

		// WS
		wsFlag     = flag.Bool("ws", false, "Enable the WS-RPC server")
		wsAddrFlag = flag.String("ws.addr", "127.0.0.1", "WS-RPC server listening interface")
		wsPortFlag = flag.Int("ws.port", 8546, "WS-RPC server listening port")
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
		if netType == core.Devnet || netType == core.Simulation {
			privKey, _ = crypto.HexToECDSA(core.DefaultDevKey)
			fmt.Printf("🔑 Loaded Default Dev Key for Devnet/Sim: %s\n", crypto.PubkeyToAddress(privKey.PublicKey).Hex())
		} else {
			if netType == core.Mainnet || netType == core.Testnet {
				fmt.Println("FATAL: Private key required for non-dev networks. Use -key flag.")
				os.Exit(1)
			}
			// Fallback (should not be reached if checks strictly enforce)
			fmt.Println("FATAL: No key provided.")
			os.Exit(1)
		}
	}

	// Bootnodes
	var bootnodes []string
	if *bootnodesFlag != "" {
		bootnodes = strings.Split(*bootnodesFlag, ",")
	}

	// Defaults if not set (but flag.Int defaults handle this partially, logic below overrides defaults if needed?)
	// Actually default in flag ("30303") is fine.

	// Datadir
	dataDir := *dataDirFlag
	if dataDir == "" {
		dataDir = "zephyria-chaindata"
	}

	// IPC
	ipcPath := *ipcFlag
	if ipcPath == "" {
		ipcPath = dataDir + "/zephyria.ipc"
	}

	// Dynamic Port Switching
	p2pPort := *portFlag
	p2pPort = findAvailableUDPPort(p2pPort)

	httpPort := *httpPortFlag
	if *httpFlag {
		httpPort = findAvailableTCPPort(httpPort)
	}

	wsPort := *wsPortFlag
	if *wsFlag {
		wsPort = findAvailableTCPPort(wsPort)
	}

	cfg := &node.Config{
		DataDir:      dataDir,
		P2PPort:      p2pPort,
		HTTPHost:     *httpAddrFlag,
		HTTPPort:     httpPort, // Use dynamic port
		HTTPEnabled:  *httpFlag,
		WSHost:       *wsAddrFlag,
		WSPort:       wsPort, // Use dynamic port
		WSEnabled:    *wsFlag,
		IPCPath:      ipcPath,
		Network:      netType,
		ValidatorKey: privKey,
		Bootnodes:    bootnodes,
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
	fmt.Printf("Enode: %s\n", n.EnodeURL()) // Show Bootnode Address
	fmt.Println("Commands: info, addkey <hex>, stake <amt> <addr>, unstake <addr>, exit")

	// 2. Interactive Loop (non-blocking if mining, but scanner blocks main thread which is fine)
	scanner := bufio.NewScanner(os.Stdin)
	for {
		fmt.Print("> ")
		if !scanner.Scan() {
			// If stdin closed (e.g. background/headless), block forever
			select {}
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

// findAvailableTCPPort checks if a port is in use and increments until availability.
func findAvailableTCPPort(start int) int {
	for port := start; port < start+100; port++ {
		ln, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
		if err == nil {
			ln.Close()
			return port
		}
	}
	return start // Fallback
}

// findAvailableUDPPort checks if a port is in use and increments until availability.
func findAvailableUDPPort(start int) int {
	for port := start; port < start+100; port++ {
		addr, err := net.ResolveUDPAddr("udp", fmt.Sprintf(":%d", port))
		if err != nil {
			continue
		}
		ln, err := net.ListenUDP("udp", addr)
		if err == nil {
			ln.Close()
			return port
		}
	}
	return start // Fallback
}
