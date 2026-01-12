package core

import (
	"math/big"
	"testing"

	"zephyria/state"
	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

func TestExecutor_Transfer(t *testing.T) {
	// Setup
	s := state.New(common.Hash{}, nil)

	key, _ := crypto.GenerateKey()
	addr := crypto.PubkeyToAddress(key.PublicKey)

	to := common.HexToAddress("0x2")

	// Fund sender
	initBal, _ := uint256.FromBig(big.NewInt(1000000000000000000)) // 1 ZEE
	s.SetBalance(addr, initBal, 0)

	config := params.AllEthashProtocolChanges
	config.ChainID = big.NewInt(99999)
	netCfg := GetNetworkConfig(Devnet)
	executor := NewExecutor(config, netCfg, nil)

	// Create Tx
	nonce := uint64(0)
	amount := big.NewInt(1000)
	gasLimit := uint64(21000)
	gasPrice := big.NewInt(10)

	tx := ethtypes.NewTransaction(nonce, to, amount, gasLimit, gasPrice, nil)
	signer := ethtypes.LatestSigner(config)
	signedTx, _ := ethtypes.SignTx(tx, signer, key)

	header := &types.Header{
		Number:   big.NewInt(1),
		Time:     1000,
		GasLimit: 10000000,
		Coinbase: common.HexToAddress("0x99"),
		BaseFee:  big.NewInt(10),
	}

	// Execute
	_, _, err := executor.ApplyBlock(s, header, []*ethtypes.Transaction{signedTx})
	if err != nil {
		t.Fatalf("ApplyBlock failed: %v", err)
	}

	// Verify
	// Sender balance = 100000 - 1000 (value) - 21000*10 (gas) = 100000 - 1000 - 210000 = negative?
	// Wait, 100000 zei is small. 21000 * 10 = 210,000.
	// So sender needs more funds.
	// Actually logic should have failed with "insufficient funds"?
	// Let's re-check funding.
}
