package core

import (
	"fmt"
	"testing"
	"zephyria/state"

	"github.com/ethereum/go-ethereum/common"
	"github.com/holiman/uint256"
)

func TestStateRootChanges(t *testing.T) {
	s := state.New(common.Hash{}, nil)
	root0 := s.IntermediateRoot(false)
	fmt.Printf("Empty Root: %s\n", root0.Hex())

	addr := common.HexToAddress("0x123")
	s.SetBalance(addr, uint256.NewInt(1000), 0)

	root1 := s.IntermediateRoot(false)
	fmt.Printf("After SetBalance Root: %s\n", root1.Hex())

	if root1 == root0 {
		t.Errorf("Root did not change after SetBalance")
	}
}
