package main

import (
	"flag"
	"fmt"
	"math/big"
	"os"
	"strings"

	"zephyria/node"

	"github.com/ethereum/go-ethereum/accounts/keystore"
	"github.com/ethereum/go-ethereum/crypto"
)

func main() {
	// Parse Flags
	port := flag.Int("port", 8545, "HTTP RPC Port")
	p2pPort := flag.Int("p2p", 30303, "P2P TCP Port")
	datadir := flag.String("datadir", "zephyria-chaindata", "Data Directory")
	bootnodes := flag.String("bootnodes", "", "Comma-separated bootnode addresses (e.g. 127.0.0.1:30303)")

	mine := flag.Bool("mine", false, "Enable Block Mining")
	network := flag.String("network", "devnet", "Network (mainnet, testnet, devnet)")
	stake := flag.String("stake", "", "Amount of ZEE to stake (e.g. '1000000000000000000')")
	unstake := flag.Bool("unstake", false, "Unstake from validator set")

	// Key management
	keyHex := flag.String("key", "", "Private key in hex format")
	keystorePath := flag.String("keystore", "", "Path to keystore file")
	password := flag.String("password", "", "Password for keystore")

	flag.Parse()

	fmt.Printf("\033[1;36m================================================================\033[0m\n")
	fmt.Printf("\033[1;36m|          Zephyria Blockchain - High Performance Mode         |\033[0m\n")
	fmt.Printf("\033[1;36m================================================================\033[0m\n")
	fmt.Printf("\033[1;34m[🚀] RPC:\033[0m :%d | \033[1;34m[🌐] P2P:\033[0m :%d | \033[1;34m[📁] Data:\033[0m %s | \033[1;34m[🌍] Net:\033[0m %s\n", *port, *p2pPort, *datadir, *network)

	// 1. Config
	cfg := node.DefaultConfig()
	cfg.Network = *network
	cfg.HTTPPort = *port
	cfg.P2PPort = *p2pPort
	cfg.DataDir = *datadir

	// Load Validator Key
	if *keyHex != "" {
		privKey, err := crypto.HexToECDSA(*keyHex)
		if err != nil {
			panic(fmt.Sprintf("Invalid private key: %v", err))
		}
		cfg.ValidatorKey = privKey
		fmt.Printf("\033[1;32m[🔑] Loaded Key from Hex:\033[0m %s\n", crypto.PubkeyToAddress(privKey.PublicKey).Hex())
	} else if *keystorePath != "" {
		if *password == "" {
			panic("Password required for keystore")
		}
		jsonBytes, err := os.ReadFile(*keystorePath)
		if err != nil {
			panic(fmt.Sprintf("Failed to read keystore: %v", err))
		}
		key, err := keystore.DecryptKey(jsonBytes, *password)
		if err != nil {
			panic(fmt.Sprintf("Failed to decrypt keystore: %v", err))
		}
		cfg.ValidatorKey = key.PrivateKey
		fmt.Printf("\033[1;32m[🔑] Loaded Key from Keystore:\033[0m %s\n", crypto.PubkeyToAddress(key.PrivateKey.PublicKey).Hex())
	}

	if *bootnodes != "" {
		cfg.Bootnodes = strings.Split(*bootnodes, ",")
	}

	// 2. Node
	n := node.New(cfg)

	// 3. Start (Init)
	if err := n.Start(); err != nil {
		panic(fmt.Sprintf("Node failed to start: %v", err))
	}

	// 4. CLI Actions
	if *stake != "" {
		amt, _ := new(big.Int).SetString(*stake, 10)
		if amt != nil {
			valAddr := crypto.PubkeyToAddress(cfg.ValidatorKey.PublicKey)
			if err := n.SendStakeTx(amt, valAddr); err != nil {
				fmt.Printf("Failed to send stake tx: %v\n", err)
			}
		}
	}

	if *unstake {
		valAddr := crypto.PubkeyToAddress(cfg.ValidatorKey.PublicKey)
		if err := n.SendUnstakeTx(valAddr); err != nil {
			fmt.Printf("Failed to send unstake tx: %v\n", err)
		}
	}

	if *mine {
		n.StartMining()
	} else if *stake != "" || *unstake {
		fmt.Println("\033[1;33m[!] Auto-enabling mining to process staking transaction...\033[0m")
		n.StartMining()
	} else {
		fmt.Println("\033[1;34m[ℹ] Node running in P2P/RPC mode (Mining Disabled)\033[0m")
	}

	// 5. Block
	n.Wait()
}
