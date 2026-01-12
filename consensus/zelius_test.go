package consensus

import (
	"math/big"
	"testing"

	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

func TestHBBFT_SimulateRound(t *testing.T) {
	v1 := common.HexToAddress("0x1")
	v2 := common.HexToAddress("0x2")
	v3 := common.HexToAddress("0x3")
	v4 := common.HexToAddress("0x4")

	validators := []*Validator{
		{Address: v1, Stake: big.NewInt(100)},
		{Address: v2, Stake: big.NewInt(100)},
		{Address: v3, Stake: big.NewInt(100)},
		{Address: v4, Stake: big.NewInt(100)},
	}

	// Generate a private key for the test engine (mocking one of the validators)
	privKey, _ := crypto.HexToECDSA("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")

	engine := NewZelius(validators, privKey, nil)

	parent := &types.Block{
		Header: &types.Header{
			Number: big.NewInt(0),
			Time:   1000,
			// Need Verkle structure but zero val is ok for mock
		},
	}

	// Input txs
	txs := []*ethtypes.Transaction{} // empty for simplicity or mock

	block, err := engine.SimulateRound(parent, txs, nil, nil)
	if err != nil {
		t.Fatalf("SimulateRound failed: %v", err)
	}

	if block.Header.Number.Uint64() != 1 {
		t.Fatalf("expected block number 1, got %d", block.Header.Number.Uint64())
	}

	if block.Header.Coinbase == (common.Address{}) {
		t.Fatalf("expected coinbase to be set")
	}
}
