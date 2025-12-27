package main

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"log"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rpc"
)

const (
	rpcURL           = "http://127.0.0.1:8545"
	stakingAddress   = "0x0000000000000000000000000000000000002000"
	validatorAddress = "0x0000000000000000000000000000000000003000"
)

func main() {
	// 1. Connect
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}

	// 2. Setup New Validator Identity
	privateKey, _ := crypto.GenerateKey()
	addr := crypto.PubkeyToAddress(privateKey.PublicKey)
	fmt.Printf("New Validator Identity: %s\n", addr.Hex())

	// 3. Fund it (Genesis Key -> New Validator)
	fmt.Println("Step 1: Funding new validator...")
	fund(client, addr)
}

func fund(client *ethclient.Client, to common.Address) {
	privKey, _ := crypto.HexToECDSA("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
	pubKey := crypto.PubkeyToAddress(privKey.PublicKey)

	nonce, err := client.PendingNonceAt(context.Background(), pubKey)
	if err != nil {
		log.Fatalf("Failed to get pending nonce: %v", err)
	}
	gasPrice, err := client.SuggestGasPrice(context.Background())
	if err != nil {
		log.Fatalf("Failed to suggest gas price: %v", err)
	}

	// Send 100 ETH
	amount := new(big.Int).Mul(big.NewInt(100), big.NewInt(1000000000000000000))
	tx := types.NewTransaction(nonce, to, amount, 21000, gasPrice, nil)
	chainID, err := client.ChainID(context.Background())
	if err != nil {
		log.Fatalf("Failed to get chain ID: %v", err)
	}
	signedTx, _ := types.SignTx(tx, types.NewEIP155Signer(chainID), privKey)

	err = client.SendTransaction(context.Background(), signedTx)
	if err != nil {
		log.Fatalf("Funding failed: %v", err)
	}
	fmt.Printf("Funding Tx Sent: %s\n", signedTx.Hash().Hex())
	waitForTx(client, signedTx.Hash())
}

func stake(client *ethclient.Client, privKey *ecdsa.PrivateKey, addr common.Address) {
	nonce, err := client.PendingNonceAt(context.Background(), addr)
	if err != nil {
		log.Fatalf("Failed to get pending nonce: %v", err)
	}
	gasPrice, err := client.SuggestGasPrice(context.Background())
	if err != nil {
		log.Fatalf("Failed to suggest gas price: %v", err)
	}
	stakingAddr := common.HexToAddress(stakingAddress)

	// Stake 10 ETH
	amount := new(big.Int).Mul(big.NewInt(10), big.NewInt(1000000000000000000))
	tx := types.NewTransaction(nonce, stakingAddr, amount, 100000, gasPrice, nil)
	chainID, err := client.ChainID(context.Background())
	if err != nil {
		log.Fatalf("Failed to get chain ID: %v", err)
	}
	signedTx, _ := types.SignTx(tx, types.NewEIP155Signer(chainID), privKey)

	err = client.SendTransaction(context.Background(), signedTx)
	if err != nil {
		log.Fatalf("Staking failed: %v", err)
	}
	fmt.Printf("Staking Tx Sent: %s\n", signedTx.Hash().Hex())
	waitForTx(client, signedTx.Hash())
}

func waitForTx(client *ethclient.Client, hash common.Hash) {
	for {
		_, isPending, err := client.TransactionByHash(context.Background(), hash)
		if err == nil && !isPending {
			receipt, err := client.TransactionReceipt(context.Background(), hash)
			if err == nil && receipt.Status == 1 {
				fmt.Println("Tx Confirmed!")
				return
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func checkValidatorCount() {
	rpcClient, _ := rpc.Dial(rpcURL)
	var result hexutil.Bytes
	// Call eth_getStorageAt for ValidatorAddr key 0
	err := rpcClient.Call(&result, "eth_getStorageAt", validatorAddress, "0x0000000000000000000000000000000000000000000000000000000000000000", "latest")
	if err != nil {
		log.Fatalf("Failed to get count: %v", err)
	}

	count := new(big.Int).SetBytes(result)
	fmt.Printf(">>> ACTIVE VALIDATOR COUNT: %s <<<\n", count.String())
}
