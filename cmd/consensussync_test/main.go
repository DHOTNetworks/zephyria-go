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

const (
	rpcURL         = "http://127.0.0.1:8545"
	stakingAddrHex = "0x0000000000000000000000000000000000001000"
	validatorAddr  = "0x0000000000000000000000000000000000003000"
	privKeyHex     = "59c6990119e98753173db85c1d15473d0922857e4e16d91f9719396be952281c"
)

func main() {
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}

	// 1. Check Initial Validator Count
	count, err := client.StorageAt(context.Background(), common.HexToAddress(validatorAddr), common.Hash{}, nil)
	if err != nil {
		log.Fatalf("Failed to check count: %v", err)
	}
	fmt.Printf("Initial Validator Count in State: %d\n", common.BytesToHash(count).Big())

	// 2. Stake
	privateKey, _ := crypto.HexToECDSA(privKeyHex)
	fromAddr := crypto.PubkeyToAddress(*(privateKey.Public().(*ecdsa.PublicKey)))
	nonce, _ := client.PendingNonceAt(context.Background(), fromAddr)
	chainID, _ := client.NetworkID(context.Background())

	// 1.5 Fund the account from Genesis
	genKey, _ := crypto.HexToECDSA("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
	genAddr := crypto.PubkeyToAddress(*(genKey.Public().(*ecdsa.PublicKey)))
	genNonce, _ := client.PendingNonceAt(context.Background(), genAddr)

	fundTx := types.NewTx(&types.DynamicFeeTx{
		ChainID: chainID, Nonce: genNonce, GasTipCap: big.NewInt(2000000000), GasFeeCap: big.NewInt(5000000000),
		Gas: 21000, To: &fromAddr, Value: big.NewInt(0).Mul(big.NewInt(1000), big.NewInt(1e18)), // 1000 ZEE
	})
	signedFundTx, _ := types.SignTx(fundTx, types.LatestSignerForChainID(chainID), genKey)
	client.SendTransaction(context.Background(), signedFundTx)
	fmt.Printf("Funding Tx Sent: %s\n", signedFundTx.Hash().Hex())
	time.Sleep(2 * time.Second)

	stakingAddr := common.HexToAddress(stakingAddrHex)
	value := big.NewInt(100) // Small stake for PoC logic

	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID:   chainID,
		Nonce:     nonce,
		GasTipCap: big.NewInt(2000000000), // 2 Gwei
		GasFeeCap: big.NewInt(5000000000), // 5 Gwei
		Gas:       100000,
		To:        &stakingAddr,
		Value:     value,
	})

	signedTx, _ := types.SignTx(tx, types.LatestSignerForChainID(chainID), privateKey)
	err = client.SendTransaction(context.Background(), signedTx)
	if err != nil {
		log.Fatalf("Failed to stake: %v", err)
	}
	fmt.Printf("Staking Tx Sent: %s\n", signedTx.Hash().Hex())

	// 3. Wait for confirmation
	for {
		receipt, err := client.TransactionReceipt(context.Background(), signedTx.Hash())
		if err == nil && receipt.Status == 1 {
			fmt.Println("Staking Confirmed!")
			break
		}
		time.Sleep(1 * time.Second)
	}

	// 4. Check Final Validator Count
	count, _ = client.StorageAt(context.Background(), common.HexToAddress(validatorAddr), common.Hash{}, nil)
	fmt.Printf("Final Validator Count in State: %d\n", common.BytesToHash(count).Big())

	// 5. Check if address is stored at index 1
	index1Key := common.BigToHash(big.NewInt(1))
	addrAtIdx1, _ := client.StorageAt(context.Background(), common.HexToAddress(validatorAddr), index1Key, nil)
	fmt.Printf("Validator at Index 1: %s\n", common.BytesToAddress(addrAtIdx1).Hex())
}
