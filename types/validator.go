package types

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

// ValidatorStatus represents the current state of a validator
type ValidatorStatus uint8

const (
	ValidatorInactive  ValidatorStatus = 0
	ValidatorActive    ValidatorStatus = 1
	ValidatorUnbonding ValidatorStatus = 2
	ValidatorSlashed   ValidatorStatus = 3
)

func (s ValidatorStatus) String() string {
	switch s {
	case ValidatorInactive:
		return "Inactive"
	case ValidatorActive:
		return "Active"
	case ValidatorUnbonding:
		return "Unbonding"
	case ValidatorSlashed:
		return "Slashed"
	default:
		return "Unknown"
	}
}

// ValidatorInfo represents the on-chain validator record
type ValidatorInfo struct {
	Address         common.Address  // Validator's Ethereum address
	Stake           *big.Int        // Current staked amount
	Name            string          // Human-readable name
	Website         string          // Validator website
	Status          ValidatorStatus // Current status
	BLSPubKey       []byte          // BLS public key (48 bytes)
	Commission      uint16          // Commission rate in basis points (0-10000)
	ActivationBlock uint64          // Block when validator became active
	SlashCount      uint32          // Number of times slashed
	TotalRewards    *big.Int        // Total rewards earned
}

// UnbondingRequest represents a pending unstake request
type UnbondingRequest struct {
	Amount       *big.Int // Amount to unbond
	UnlockBlock  uint64   // Block when funds unlock
	RequestBlock uint64   // Block when request was made
}

// SlashingType represents the type of slashable offense
type SlashingType uint8

const (
	SlashingDoubleSign   SlashingType = 0
	SlashingDowntime     SlashingType = 1
	SlashingInvalidBlock SlashingType = 2
	SlashingInvalidVote  SlashingType = 3
)

func (s SlashingType) String() string {
	switch s {
	case SlashingDoubleSign:
		return "DoubleSign"
	case SlashingDowntime:
		return "Downtime"
	case SlashingInvalidBlock:
		return "InvalidBlock"
	case SlashingInvalidVote:
		return "InvalidVote"
	default:
		return "Unknown"
	}
}

// SlashingRecord represents an on-chain slashing event
type SlashingRecord struct {
	ValidatorAddr common.Address // Slashed validator
	SlashType     SlashingType   // Type of offense
	Evidence      []byte         // RLP-encoded evidence
	SlashAmount   *big.Int       // Amount slashed
	BlockNumber   uint64         // Block when slashing occurred
	Reporter      common.Address // Address that reported (if applicable)
}

// DoubleSignEvidence represents proof of double signing
type DoubleSignEvidence struct {
	BlockHash1 common.Hash // First block hash
	BlockHash2 common.Hash // Second block hash (different from first)
	Signature1 []byte      // Signature on first block
	Signature2 []byte      // Signature on second block
	Height     uint64      // Block height (same for both)
	BLSPubKey  []byte      // BLS public key of validator
}

// ValidatorEvent represents events emitted by the staking contract
type ValidatorEvent struct {
	Type      string         // Event type: "Registered", "Unstaked", "Slashed", etc.
	Validator common.Address // Validator address
	Amount    *big.Int       // Amount (stake/slash/reward)
	BlockNum  uint64         // Block number
	Data      []byte         // Additional event data
}

// StakingConstants defines the staking system parameters
type StakingConstants struct {
	MinStake        *big.Int // Minimum stake required (1 ETH = 1e18)
	MaxStake        *big.Int // Maximum stake allowed
	UnbondingPeriod uint64   // Blocks to wait for unstaking (1000 blocks)
	SlashPercentage uint8    // Percentage to slash (50%)
	MaxValidators   uint64   // Maximum number of validators (10000)
}

// DefaultStakingConstants returns the default staking parameters
func DefaultStakingConstants() *StakingConstants {
	minStake := new(big.Int).SetUint64(1000000000000000000)                // 1 token (1e18)
	maxStake, _ := new(big.Int).SetString("1000000000000000000000000", 10) // 1M tokens (1e24)

	return &StakingConstants{
		MinStake:        minStake,
		MaxStake:        maxStake,
		UnbondingPeriod: 1000,
		SlashPercentage: 50,
		MaxValidators:   10000,
	}
}
