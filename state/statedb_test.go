package state

import (
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/holiman/uint256"
)

func TestStateDB_Balance(t *testing.T) {
	s := New(common.Hash{}, nil)
	addr := common.HexToAddress("0x1")

	// Check initial balance
	if !s.GetBalance(addr).IsZero() {
		t.Fatalf("expected 0 balance, got %v", s.GetBalance(addr))
	}

	// Set balance
	val := uint256.NewInt(100)
	s.SetBalance(addr, val, tracing.BalanceChangeReason(0))

	if !s.GetBalance(addr).Eq(val) {
		t.Fatalf("expected %v balance, got %v", val, s.GetBalance(addr))
	}

	// Add balance
	add := uint256.NewInt(50)
	s.AddBalance(addr, add, tracing.BalanceChangeReason(0))
	expected := uint256.NewInt(150)

	if !s.GetBalance(addr).Eq(expected) {
		t.Fatalf("expected %v balance, got %v", expected, s.GetBalance(addr))
	}

	// Sub balance
	sub := uint256.NewInt(50)
	s.SubBalance(addr, sub, tracing.BalanceChangeReason(0))
	expected = uint256.NewInt(100)

	if !s.GetBalance(addr).Eq(expected) {
		t.Fatalf("expected %v balance, got %v", expected, s.GetBalance(addr))
	}
}

func TestStateDB_Nonce(t *testing.T) {
	s := New(common.Hash{}, nil)
	addr := common.HexToAddress("0x2")

	if s.GetNonce(addr) != 0 {
		t.Fatalf("expected nonce 0, got %d", s.GetNonce(addr))
	}

	s.SetNonce(addr, 5, tracing.NonceChangeReason(0))
	if s.GetNonce(addr) != 5 {
		t.Fatalf("expected nonce 5, got %d", s.GetNonce(addr))
	}
}

func TestStateDB_State(t *testing.T) {
	s := New(common.Hash{}, nil)
	addr := common.HexToAddress("0x3")
	key := common.BytesToHash([]byte("key"))
	val := common.BytesToHash([]byte("value"))

	if s.GetState(addr, key) != (common.Hash{}) {
		t.Fatalf("expected empty state, got %v", s.GetState(addr, key))
	}

	s.SetState(addr, key, val)

	if s.GetState(addr, key) != val {
		t.Fatalf("expected state %v, got %v", val, s.GetState(addr, key))
	}
}

func TestStateDB_Code(t *testing.T) {
	s := New(common.Hash{}, nil)
	addr := common.HexToAddress("0x4")
	code := []byte{0x01, 0x02, 0x03}

	if len(s.GetCode(addr)) != 0 {
		t.Fatalf("expected empty code")
	}

	s.SetCode(addr, code, tracing.CodeChangeReason(0))

	if len(s.GetCode(addr)) != 3 {
		t.Fatalf("expected code len 3")
	}

	h := crypto.Keccak256Hash(code)
	if s.GetCodeHash(addr) != h {
		t.Fatalf("code hash mismatch")
	}
}
