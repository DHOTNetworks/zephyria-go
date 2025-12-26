package core

import (
	"math/big"
	"time"

	"zephyria/consensus"
	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

// Network types
const (
	Mainnet    = "mainnet"
	Testnet    = "testnet"
	Devnet     = "devnet"
	Simulation = "simulation"
)

// DefaultDevKey is the hardcoded private key for the default validator in dev/poc mode.
const DefaultDevKey = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

// NetworkConfig holds all parameters for a specific network
type NetworkConfig struct {
	ChainID      *big.Int
	GenesisTime  uint64
	GenesisHash  common.Hash // Expected hash of the genesis block
	Difficulty   *big.Int
	GasLimit     uint64
	BaseFee      *big.Int
	Coinbase     common.Address
	Alloc        map[common.Address]*uint256.Int
	Validators   []*consensus.Validator
	ConsensusCfg ConsensusConfig
	Params       SystemParams
}

// SystemParams holds network-wide constants
type SystemParams struct {
	StakingAddr     common.Address
	RewardAddr      common.Address
	ValidatorAddr   common.Address
	DefaultGasLimit uint64
	DefaultBaseFee  *big.Int
}

// ConsensusConfig holds engine-specific parameters
type ConsensusConfig struct {
	BlockTimeout time.Duration
}

// ChainConfig returns the params.ChainConfig for this network
func (c *NetworkConfig) ChainConfig() *params.ChainConfig {
	return &params.ChainConfig{
		ChainID:             c.ChainID,
		HomesteadBlock:      big.NewInt(0),
		DAOForkBlock:        big.NewInt(0),
		EIP150Block:         big.NewInt(0),
		EIP155Block:         big.NewInt(0),
		EIP158Block:         big.NewInt(0),
		ByzantiumBlock:      big.NewInt(0),
		ConstantinopleBlock: big.NewInt(0),
		PetersburgBlock:     big.NewInt(0),
		IstanbulBlock:       big.NewInt(0),
		MuirGlacierBlock:    big.NewInt(0),
		BerlinBlock:         big.NewInt(0),
		LondonBlock:         big.NewInt(0),
	}
}

// GetNetworkConfig returns parameters for the requested network
func GetNetworkConfig(network string) *NetworkConfig {
	var cfg *NetworkConfig
	switch network {
	case Mainnet:
		cfg = &NetworkConfig{
			ChainID:     big.NewInt(1),
			GenesisTime: uint64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix()),
			GenesisHash: common.HexToHash("0x6241bba4b608b79c6bd0aeac71ea0fbb7ca1eebd16e5538b77bef399368da24a"),
			Difficulty:  big.NewInt(1),
			GasLimit:    60000000,
			BaseFee:     big.NewInt(100),
			Coinbase:    common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
			Validators:  DefaultValidators(),
			ConsensusCfg: ConsensusConfig{
				BlockTimeout: 1000 * time.Millisecond,
			},
			Params: SystemParams{
				StakingAddr:     common.HexToAddress("0x0000000000000000000000000000000000001000"),
				RewardAddr:      common.HexToAddress("0x0000000000000000000000000000000000002000"),
				ValidatorAddr:   common.HexToAddress("0x0000000000000000000000000000000000003000"),
				DefaultGasLimit: 60000000,
				DefaultBaseFee:  big.NewInt(100),
			},
		}
	case Testnet:
		cfg = &NetworkConfig{
			ChainID:     big.NewInt(1337),
			GenesisTime: uint64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix()),
			GenesisHash: common.HexToHash("0x6241bba4b608b79c6bd0aeac71ea0fbb7ca1eebd16e5538b77bef399368da24a"),
			Difficulty:  big.NewInt(1),
			GasLimit:    60000000,
			BaseFee:     big.NewInt(100),
			Coinbase:    common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
			Validators:  DefaultValidators(),
			ConsensusCfg: ConsensusConfig{
				BlockTimeout: 500 * time.Millisecond,
			},
			Params: SystemParams{
				StakingAddr:     common.HexToAddress("0x0000000000000000000000000000000000001000"),
				RewardAddr:      common.HexToAddress("0x0000000000000000000000000000000000002000"),
				ValidatorAddr:   common.HexToAddress("0x0000000000000000000000000000000000003000"),
				DefaultGasLimit: 60000000,
				DefaultBaseFee:  big.NewInt(100),
			},
		}
	case Simulation:
		cfg = &NetworkConfig{
			ChainID:     big.NewInt(1338), // Different Chain ID
			GenesisTime: uint64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix()),
			GenesisHash: common.HexToHash("0x6241bba4b608b79c6bd0aeac71ea0fbb7ca1eebd16e5538b77bef399368da24a"), // Matches generated block
			Difficulty:  big.NewInt(1),
			GasLimit:    60000000,
			BaseFee:     big.NewInt(100),
			Coinbase:    common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
			Validators:  SimulationValidators(),
			ConsensusCfg: ConsensusConfig{
				BlockTimeout: 500 * time.Millisecond,
			},
			Params: SystemParams{
				StakingAddr:     common.HexToAddress("0x0000000000000000000000000000000000001000"),
				RewardAddr:      common.HexToAddress("0x0000000000000000000000000000000000002000"),
				ValidatorAddr:   common.HexToAddress("0x0000000000000000000000000000000000003000"),
				DefaultGasLimit: 60000000,
				DefaultBaseFee:  big.NewInt(100),
			},
		}

	default: // Devnet / Default
		cfg = &NetworkConfig{
			ChainID:     big.NewInt(1337),
			GenesisTime: uint64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix()),
			GenesisHash: common.HexToHash("0x6241bba4b608b79c6bd0aeac71ea0fbb7ca1eebd16e5538b77bef399368da24a"),
			Difficulty:  big.NewInt(1),
			GasLimit:    60000000,
			BaseFee:     big.NewInt(100),
			Coinbase:    common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
			Validators:  []*consensus.Validator{{Address: common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"), Stake: big.NewInt(100)}},
			ConsensusCfg: ConsensusConfig{
				BlockTimeout: 200 * time.Millisecond,
			},
			Params: SystemParams{
				StakingAddr:     common.HexToAddress("0x0000000000000000000000000000000000001000"),
				RewardAddr:      common.HexToAddress("0x0000000000000000000000000000000000002000"),
				ValidatorAddr:   common.HexToAddress("0x0000000000000000000000000000000000003000"),
				DefaultGasLimit: 60000000,
				DefaultBaseFee:  big.NewInt(100),
			},
		}
	}
	cfg.Alloc = GenesisAlloc(cfg)
	return cfg
}

// DefaultValidators returns the hardcoded initial validator set
func DefaultValidators() []*consensus.Validator {
	return []*consensus.Validator{
		{Address: common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"), Stake: big.NewInt(100)},
		{Address: common.HexToAddress("0x96216849c49358B10257cb55b28eA603c874b05E"), Stake: big.NewInt(100)},
		{Address: common.HexToAddress("0x627306090abaB3A6e1400e9345bC60c78a8BEf57"), Stake: big.NewInt(100)},
		{Address: common.HexToAddress("0xf17f52151EbEF6C7334FAD080c5704D77216b732"), Stake: big.NewInt(100)},
	}
}

// SimulationValidators returns 4 hardcoded validators for simulation
func SimulationValidators() []*consensus.Validator {
	return []*consensus.Validator{
		// 4 Fixed Keys (Same as in simulation/main.go)
		{Address: common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"), Stake: big.NewInt(100)}, // Val 0
		{Address: common.HexToAddress("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"), Stake: big.NewInt(100)}, // Val 1
		{Address: common.HexToAddress("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"), Stake: big.NewInt(100)}, // Val 2
		{Address: common.HexToAddress("0x90F79bf6EB2c4f870365E785982E1f101E93b906"), Stake: big.NewInt(100)}, // Val 3
	}
}

// DefaultChainConfig returns the default hardcoded chain configuration
func DefaultChainConfig() *params.ChainConfig {
	return &params.ChainConfig{
		ChainID:             big.NewInt(1337),
		HomesteadBlock:      big.NewInt(0),
		DAOForkBlock:        big.NewInt(0),
		EIP150Block:         big.NewInt(0),
		EIP155Block:         big.NewInt(0),
		EIP158Block:         big.NewInt(0),
		ByzantiumBlock:      big.NewInt(0),
		ConstantinopleBlock: big.NewInt(0),
		PetersburgBlock:     big.NewInt(0),
		IstanbulBlock:       big.NewInt(0),
		MuirGlacierBlock:    big.NewInt(0),
		BerlinBlock:         big.NewInt(0),
		LondonBlock:         big.NewInt(0),
	}
}

// GenerateGenesisBlock creates the hardcoded genesis block for a config
func GenerateGenesisBlock(cfg *NetworkConfig) *types.Block {
	header := &types.Header{
		Number:     big.NewInt(0),
		Time:       cfg.GenesisTime,
		ParentHash: common.Hash{},
		Difficulty: cfg.Difficulty,
		GasLimit:   cfg.GasLimit,
		BaseFee:    cfg.BaseFee,
		Coinbase:   cfg.Coinbase,
	}
	return types.NewBlock(header, nil)
}

// GenesisAlloc returns default allocations
func GenesisAlloc(cfg *NetworkConfig) map[common.Address]*uint256.Int {
	alloc := make(map[common.Address]*uint256.Int)
	userAddr := common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")
	amt, _ := new(big.Int).SetString("1000000000000000000000000", 10)
	balance, _ := uint256.FromBig(amt)
	alloc[userAddr] = balance

	// Initialize System Contracts with 1 ZEE each (optional, for visibility)
	sysAmt := new(big.Int).SetUint64(1000000000000000000)
	sysBal, _ := uint256.FromBig(sysAmt)
	alloc[cfg.Params.StakingAddr] = sysBal
	alloc[cfg.Params.RewardAddr] = sysBal
	alloc[cfg.Params.ValidatorAddr] = sysBal

	return alloc
}
