package main

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"log"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// Genesis Private Key for Devnet (from core/genesis.go)
// DefaultDevKey = "b71c71a67e1177ad4e901695e1b4b9ee17ae16c6668d313eac2f96dbcda3f291"
const privKeyHex = "b71c71a67e1177ad4e901695e1b4b9ee17ae16c6668d313eac2f96dbcda3f291"

func main() {
	client, err := ethclient.Dial("http://127.0.0.1:8545")
	if err != nil {
		log.Fatalf("Failed to connect to the Ethereum client: %v", err)
	}

	privateKey, err := crypto.HexToECDSA(privKeyHex)
	if err != nil {
		log.Fatal(err)
	}

	publicKey := privateKey.Public()
	publicKeyECDSA, ok := publicKey.(*ecdsa.PublicKey)
	if !ok {
		log.Fatal("error casting public key to ECDSA")
	}

	fromAddress := crypto.PubkeyToAddress(*publicKeyECDSA)
	fmt.Printf("Sender Address: %s\n", fromAddress.Hex())

	nonce, err := client.PendingNonceAt(context.Background(), fromAddress)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("Current Nonce: %d\n", nonce)

	// Send to self or random address
	toAddress := common.HexToAddress("0x70997970C51812dc3A010C7d01b50e0d17dc79C8") // Test account
	value := big.NewInt(1000000000000000000)                                       // 1 ZEE (10^18 wei)

	// Gas Config
	gasLimit := uint64(21000) // in units

	// EIP-1559 Fees
	tip, err := client.SuggestGasTipCap(context.Background())
	if err != nil {
		log.Fatalf("Failed to get tip: %v", err)
	}

	head, err := client.HeaderByNumber(context.Background(), nil)
	if err != nil {
		log.Fatal(err)
	}
	baseFee := head.BaseFee
	fmt.Printf("Base Fee: %s\n", baseFee.String())
	fmt.Printf("Tip Cap: %s\n", tip.String())

	// GasFeeCap = BaseFee * 2 + Tip
	gasFeeCap := new(big.Int).Add(
		new(big.Int).Mul(baseFee, big.NewInt(2)),
		tip,
	)

	chainID, err := client.NetworkID(context.Background())
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("Chain ID: %s\n", chainID.String())

	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID:   chainID,
		Nonce:     nonce,
		GasTipCap: tip,
		GasFeeCap: gasFeeCap,
		Gas:       gasLimit,
		To:        &toAddress,
		Value:     value,
		Data:      nil,
	})

	signedTx, err := types.SignTx(tx, types.LatestSignerForChainID(chainID), privateKey)
	if err != nil {
		log.Fatal(err)
	}

	err = client.SendTransaction(context.Background(), signedTx)
	if err != nil {
		log.Fatalf("Failed to send tx: %v", err)
	}

	fmt.Printf("Transaction sent! Hash: %s\n", signedTx.Hash().Hex())

	// Wait for receipt
	fmt.Println("Waiting for receipt...")
	for {
		receipt, err := client.TransactionReceipt(context.Background(), signedTx.Hash())
		if err == nil {
			fmt.Printf("Receipt found! Status: %d, Block: %s\n", receipt.Status, receipt.BlockNumber.String())
			if receipt.Status == 1 {
				fmt.Println("SUCCESS: Transaction confirmed.")
			} else {
				fmt.Println("FAILURE: Transaction reverted.")
			}
			break
		}
		time.Sleep(1 * time.Second)
	}
}
