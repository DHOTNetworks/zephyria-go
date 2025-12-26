package state

import (
	"fmt"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-verkle"
)

func TestVerkleCommitFix(t *testing.T) {
	tree := verkle.New()

	key := make([]byte, 32)
	key[31] = 0x01
	val := make([]byte, 32)
	val[31] = 0x01

	tree.Insert(key, val, nil)

	// CRITICAL FIX: CALL COMMIT
	tree.Commit()

	h := tree.Hash()
	fmt.Printf("Hash after Commit: %v\n", h)

	bytes := h.BytesLE()
	root := common.BytesToHash(bytes[:])
	fmt.Printf("Common Hash: %s\n", root.Hex())

	if root == (common.Hash{}) {
		t.Errorf("Root is still zero")
	}
}
