package main

import (
	"context"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

const (
	rpcURL = "http://127.0.0.1:8545"
	// Private key from dev/genesis (0xf39...266)
	privKeyHex = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
)

// Simple "Storage" contract bytecode
var contractBytecode = common.FromHex("608060405234801561001057600080fd5b5061012f806100206000396000f3fe608060405234801561001057600080fd5b50600436106100365760003560e01c806360fe47b11461003b5780636d4ce63c14610057575b600080fd5b610055600480360381019061005091906100c3565b610075565b005b61005f61007f565b60405161006c91906100ff565b60405180910390f35b8060008190555050565b60005481565b600080fd5b6000819050919050565b6100a08161008d565b81146100ab57600080fd5b50565b6000813590506100bd81610097565b92915050565b6000602082840312156100d9576100d8610088565b5b60006100e7848285016100ae565b91505092915050565b6100f98161008d565b82525050565b600060208201905061011460008301846100f0565b9291505056fea264697066735822122047c7c02453664796328325cd602737229743588974860163353592318728d70e64736f6c63430008070033")

func main() {
	client, err := ethclient.Dial(rpcURL)
	if err != nil {
		fmt.Printf("Failed to connect: %v\n", err)
		return
	}
	ctx := context.Background()

	key, _ := crypto.HexToECDSA(privKeyHex)
	addr := crypto.PubkeyToAddress(key.PublicKey)

	nonce, _ := client.PendingNonceAt(ctx, addr)
	gasPrice, _ := client.SuggestGasPrice(ctx)
	chainID, _ := client.ChainID(ctx)

	// Contract Creation: To address is nil
	tx := types.NewContractCreation(nonce, big.NewInt(0), 3000000, gasPrice, contractBytecode)

	// 1. Test EstimateGas
	msg := ethereum.CallMsg{
		From:     addr,
		To:       nil, // Contract creation
		Gas:      0,
		GasPrice: gasPrice,
		Value:    big.NewInt(0),
		Data:     contractBytecode,
	}
	fmt.Printf("DEBUG: Using Gas Price: %s\n", gasPrice.String())

	estGas, err := client.EstimateGas(ctx, msg)
	if err != nil {
		fmt.Printf("❌ EstimateGas Failed: %v\n", err)
		// Don't return, try sending anyway to see if it works
	} else {
		fmt.Printf("✅ EstimateGas Succeeded: %d\n", estGas)
	}

	// Explicitly creating a legacy transaction structure to be sure
	// NewContractCreation returns a legacy Tx (type 0) wrapped
	fmt.Printf("DEBUG: Tx Type: %d (0=Legacy, 2=EIP1559)\n", tx.Type())

	signedTx, _ := types.SignTx(tx, types.NewEIP155Signer(chainID), key)
	fmt.Printf("DEBUG: Signed Tx Hash: %s\n", signedTx.Hash().Hex())
	fmt.Printf("DEBUG: Sender Address: %s\n", addr.Hex())
	fmt.Printf("DEBUG: Sender Nonce: %d\n", nonce)
	fmt.Printf("DEBUG: Chain ID: %s\n", chainID.String())

	fmt.Printf("Deploying Contract... Hash: %s\n", signedTx.Hash().Hex())

	err = client.SendTransaction(ctx, signedTx)
	if err != nil {
		fmt.Printf("❌ SendTransaction Failed: %v\n", err)
		return
	}

	// Wait for receipt
	for i := 0; i < 10; i++ {
		receipt, err := client.TransactionReceipt(ctx, signedTx.Hash())
		if err == nil {
			fmt.Printf("✅ Receipt Found! Status: %d, Contract Address: %s\n", receipt.Status, receipt.ContractAddress.Hex())
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	fmt.Println("❌ Timeout waiting for receipt")
}
