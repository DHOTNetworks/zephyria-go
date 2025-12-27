package main

import (
	"context"
	"fmt"
	"log"
	"math/big"
	"net/http"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/ethereum/go-ethereum/rpc"
)

const (
	rpcURL     = "http://127.0.0.1:8545"
	privateKey = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" // Default Dev Key
)

func main() {
	fmt.Println("🦊 Starting MetaMask Simulation (Contract Creation)...")

	// 1. CORS Pre-flight Check (OPTIONS)
	fmt.Println("\n[1/5] Testing CORS (OPTIONS request)...")
	req, _ := http.NewRequest("OPTIONS", rpcURL, nil)
	req.Header.Set("Origin", "chrome-extension://nkbihfbeogaeaoehlefnkodbefgpgknn")
	req.Header.Set("Access-Control-Request-Method", "POST")
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		log.Fatalf("❌ CORS Request Failed: %v", err)
	}
	defer resp.Body.Close()
	fmt.Printf("✅ CORS OK. Allow-Origin: %s\n", resp.Header.Get("Access-Control-Allow-Origin"))

	// 2. Connect RPC with Retry
	fmt.Println("\n[2/5] Connecting to RPC...")
	var rpcClient *rpc.Client
	for i := 0; i < 5; i++ {
		rpcClient, err = rpc.DialContext(context.Background(), rpcURL)
		if err == nil {
			// Test ping
			ec := ethclient.NewClient(rpcClient)
			_, err = ec.ChainID(context.Background())
			if err == nil {
				break
			}
		}
		fmt.Printf(" ... Retrying connection (%d/5)...\n", i+1)
		time.Sleep(1 * time.Second)
	}
	if err != nil {
		log.Fatalf("❌ Failed to connect to RPC: %v", err)
	}
	ec := ethclient.NewClient(rpcClient)
	chainID, _ := ec.ChainID(context.Background())
	fmt.Printf("✅ Connected. Chain ID: %s\n", chainID.String())

	// 3. Fetch Account Info
	fmt.Println("\n[3/5] Fetching Account Info...")
	key, _ := crypto.HexToECDSA(privateKey)
	addr := crypto.PubkeyToAddress(key.PublicKey)
	nonce, _ := ec.NonceAt(context.Background(), addr, nil)
	fmt.Printf("✅ Account: %s, Nonce: %d\n", addr.Hex(), nonce)

	// 4. Estimate Gas (Contract Creation)
	fmt.Println("\n[4/5] Simulating Contract Creation (EstimateGas)...")
	contractCode := "0x6080604052348015600f57600080fd5b50603580601d6000396000f3006080604052600080fd00a165627a7a72305820e2e2ecf5b902f3a2336341257124f9640989f6655513689456345635352634560029"
	callMsg := map[string]interface{}{
		"from": addr.Hex(),
		"data": contractCode,
	}
	var gasEstHex string
	err = rpcClient.CallContext(context.Background(), &gasEstHex, "eth_estimateGas", callMsg)
	if err != nil {
		log.Fatalf("❌ EstimateGas Failed: %v", err)
	}
	fmt.Printf("✅ EstimateGas success: %s\n", gasEstHex)

	// 5. Submit Transaction (Value Transfer)
	fmt.Println("\n[5/5] Submitting Real Transaction...")
	gasPrice := big.NewInt(20000000000)
	tx := types.NewTransaction(nonce, addr, big.NewInt(1000), 21000, gasPrice, nil)

	// Use EIP155 Signer
	signer := types.NewEIP155Signer(chainID)
	signedTx, _ := types.SignTx(tx, signer, key)

	data, _ := signedTx.MarshalBinary()

	var txHash common.Hash
	// Use CallContext with hexutil.Bytes to ensure correct encoding
	err = rpcClient.CallContext(context.Background(), &txHash, "eth_sendRawTransaction", hexutil.Bytes(data))
	if err != nil {
		log.Fatalf("❌ SendRawTransaction Failed: %v", err)
	}
	fmt.Printf("✅ Tx Submitted: %s\n", txHash.Hex())
}
