package rpc

import (
	"context"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

// StakingBackend defines the methods required for the staking API.
// Implemented by node.Node.
type StakingBackend interface {
	SendStakeTx(amount *big.Int, from common.Address) error
	SendUnstakeTx(from common.Address) error
	// Helper to get validators if needed, but for now just actions
}

// ZephyriaAPI exports the Zelius specific RPC methods.
type ZephyriaAPI struct {
	backend StakingBackend
}

// NewZephyriaAPI creates a new API instance.
func NewZephyriaAPI(backend StakingBackend) *ZephyriaAPI {
	return &ZephyriaAPI{backend: backend}
}

// Stake submits a staking transaction for the given address.
func (api *ZephyriaAPI) Stake(ctx context.Context, author common.Address, amount *hexutil.Big) (bool, error) {
	// amount is hexutil.Big pointer
	amt := (*big.Int)(amount)
	if err := api.backend.SendStakeTx(amt, author); err != nil {
		return false, err
	}
	return true, nil
}

// Unstake submits an unstake transaction for the given address.
func (api *ZephyriaAPI) Unstake(ctx context.Context, author common.Address) (bool, error) {
	if err := api.backend.SendUnstakeTx(author); err != nil {
		return false, err
	}
	return true, nil
}
