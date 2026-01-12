package types

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

// SystemParams holds network-wide constants
type SystemParams struct {
	StakingAddr     common.Address
	RewardAddr      common.Address
	ValidatorAddr   common.Address
	RandomnessAddr  common.Address
	DefaultGasLimit uint64
	DefaultBaseFee  *big.Int

	// VDF Consensus Parameters
	VDFIterations int
	VDFInterval   int // Checkpoint Interval
}
