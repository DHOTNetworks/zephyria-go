package main

import (
	"context"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

const (
	rpcURL = "http://127.0.0.1:8545"
	// Private key from dev/genesis (0x...1)
	// Private key from dev/genesis (0xf39...266)
	privKeyHex = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
)

func main() {
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		fmt.Printf("Failed to connect: %v\n", err)
		return
	}
	ctx := context.Background()

	// 1. ChainID
	cid, err := client.ChainID(ctx)
	if err != nil {
		fmt.Printf("ChainID failed: %v\n", err)
		return
	}
	fmt.Printf("[✓] ChainID: %s\n", cid)

	// 2. Block Number
	num, err := client.BlockNumber(ctx)
	if err != nil {
		fmt.Printf("BlockNumber failed: %v\n", err)
		return
	}
	fmt.Printf("[✓] Block Number: %d\n", num)

	// 3. Balance
	key, _ := crypto.HexToECDSA(privKeyHex)
	addr := crypto.PubkeyToAddress(key.PublicKey)
	bal, err := client.BalanceAt(ctx, addr, nil)
	if err != nil {
		fmt.Printf("Balance failed: %v\n", err)
		return
	}
	fmt.Printf("[✓] Sender Balance: %s\n", bal)

	// 4. Send Transaction
	nonce, err := client.PendingNonceAt(ctx, addr)
	if err != nil {
		fmt.Printf("Nonce failed: %v\n", err)
		return
	}

	to := common.HexToAddress("0x1234567890123456789012345678901234567890")
	value := big.NewInt(1000000000000000000) // 1 ZEE
	gasLimit := uint64(21000)
	gasPrice, err := client.SuggestGasPrice(ctx)
	if err != nil {
		fmt.Printf("SuggestPrice failed: %v\n", err)
		return
	}

	tx := types.NewTransaction(nonce, to, value, gasLimit, gasPrice, nil)
	signedTx, _ := types.SignTx(tx, types.NewEIP155Signer(cid), key)

	fmt.Printf("Sending Tx: %s\n", signedTx.Hash().Hex())
	if err := client.SendTransaction(ctx, signedTx); err != nil {
		fmt.Printf("SendTransaction failed: %v\n", err)
		return
	}

	// 5. Wait for Receipt
	fmt.Println("Waiting for receipt...")
	for i := 0; i < 10; i++ {
		receipt, err := client.TransactionReceipt(ctx, signedTx.Hash())
		if err == nil {
			fmt.Printf("[✓] Receipt Found! Status: %d, GasUsed: %d\n", receipt.Status, receipt.GasUsed)

			// Check Balance deduction
			newBal, _ := client.BalanceAt(ctx, addr, nil)
			// Expected: old - 1 ZEE - (GasUsed*GasPrice)
			diff := new(big.Int).Sub(bal, newBal)
			fmt.Printf("[✓] Balance decreased by: %s\n", diff)
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	fmt.Println("[!] Timeout waiting for receipt")
}
