package core

import (
	"math/big"
	"time"

	"zephyria/consensus"
	"zephyria/state"
	"zephyria/types"

	bls12381 "github.com/consensys/gnark-crypto/ecc/bls12-381"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
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

// TokenProgramBytecode is the compiled code for the Native Token Bridge.
var TokenProgramBytecode = common.FromHex("608060405234801561000f575f5ffd5b5060043610610085575f3560e01c80639eee6484116100585780639eee6484146100ee578063a9059cbb14610103578063cd6dc68714610126578063e8a0aed314610138575f5ffd5b806306fdde0314610089578063313ce567146100a757806370a08231146100c657806395d89b41146100e6575b5f5ffd5b610091610163565b60405161009e919061052e565b60405180910390f35b6002546100b49060ff1681565b60405160ff909116815260200161009e565b6100d86100d4366004610562565b5490565b60405190815260200161009e565b6100916101ee565b6101016100fc36600461061a565b6101fb565b005b610116610111366004610697565b61022c565b604051901515815260200161009e565b610101610134366004610697565b9055565b61014b61014636600461061a565b610346565b6040516001600160a01b03909116815260200161009e565b5f805461016f906106bf565b80601f016020809104026020016040519081016040528092919081815260200182805461019b906106bf565b80156101e65780601f106101bd576101008083540402835291602001916101e6565b820191905f5260205f20905b8154815290600101906020018083116101c957829003601f168201915b505050505081565b6001805461016f906106bf565b5f610206848261074e565b506001610213838261074e565b506002805460ff191660ff929092169190911790555050565b5f336001600160a01b0384166102895760405162461bcd60e51b815260206004820152601860248201527f5472616e7366657220746f207a65726f2061646472657373000000000000000060448201526064015b60405180910390fd5b80545f848210156102d35760405162461bcd60e51b8152602060048201526014602482015273496e73756666696369656e742062616c616e636560601b6044820152606401610280565b6102dd8583610821565b91506102e98582610834565b5050845481835584018086556040518581526001600160a01b0380881691908516907fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef9060200160405180910390a3600193505050505b92915050565b604051733d602d80600a3d3981f3363d3d373d3d3d363d7360601b81523060601b601482018190526e5af43d82803e903d91602b57fd5bf360881b60288301525f9160378184f09250506001600160a01b0382166103d45760405162461bcd60e51b815260206004820152600b60248201526a4641494c5f43524541544560a81b6044820152606401610280565b6001600160a01b03821663cd6dc687336103f260ff8716600a61092a565b6103ff90620f4240610935565b6040516001600160e01b031960e085901b1681526001600160a01b03909216600483015260248201526044015f604051808303815f87803b158015610442575f5ffd5b505af1158015610454573d5f5f3e3d5ffd5b50506040516327bb992160e21b81526001600160a01b0385169250639eee648491506104889088908890889060040161094c565b5f604051808303815f87803b15801561049f575f5ffd5b505af11580156104b1573d5f5f3e3d5ffd5b505060405160ff861681523392506001600160a01b03851691507f5de9f27ab21b3e73cfe41499c0a0eea824ffebfdf6dcd4c92a7332e4920309e79060200160405180910390a3509392505050565b5f81518084528060208401602086015e5f602082860101526020601f19601f83011685010191505092915050565b602081525f6105406020830184610500565b9392505050565b80356001600160a01b038116811461055d575f5ffd5b919050565b5f60208284031215610572575f5ffd5b61054082610547565b634e487b7160e01b5f52604160045260245ffd5b5f82601f83011261059e575f5ffd5b813567ffffffffffffffff8111156105b8576105b861057b565b604051601f8201601f19908116603f0116810167ffffffffffffffff811182821017156105e7576105e761057b565b6040528181528382016020018510156105fe575f5ffd5b816020850160208301375f918101602001919091529392505050565b5f5f5f6060848603121561062c575f5ffd5b833567ffffffffffffffff811115610642575f5ffd5b61064e8682870161058f565b935050602084013567ffffffffffffffff81111561066a575f5ffd5b6106768682870161058f565b925050604084013560ff8116811461068c575f5ffd5b809150509250925092565b5f5f604083850312156106a8575f5ffd5b6106b183610547565b946020939093013593505050565b600181811c908216806106d357607f821691505b6020821081036106f157634e487b7160e01b5f52602260045260245ffd5b50919050565b601f821115610749578282111561074957805f5260205f20601f840160051c602085101561072257505f5b90810190601f840160051c035f5b81811015610745575f83820155600101610730565b5050505b505050565b815167ffffffffffffffff8111156107685761076861057b565b61077c8161077684546106bf565b846106f7565b6020601f8211600181146107ae575f83156107975750848201515b5f19600385901b1c1916600184901b178455610806565b5f84815260208120601f198516915b828110156107dd57878501518255602094850194600190920191016107bd565b50848210156107fa57868401515f19600387901b60f8161c191681555b505060018360011b0184555b5050505050565b634e487b7160e01b5f52601160045260245ffd5b818103818111156103405761034061080d565b808201808211156103405761034061080d565b6001815b6001841115610882578085048111156108665761086661080d565b600184161561087457908102905b60019390931c92800261084b565b935093915050565b5f8261089857506001610340565b816108a457505f610340565b81600181146108ba57600281146108c4576108e0565b6001915050610340565b60ff8411156108d5576108d561080d565b50506001821b610340565b5060208310610133831016604e8410600b8410161715610903575081810a610340565b61090f5f198484610847565b805f19048211156109225761092261080d565b029392505050565b5f610540838361088a565b80820281158282048414176103405761034061080d565b606081525f61095e6060830186610500565b82810360208401526109708186610500565b91505060ff8316604083015294935050505056fea2646970667358221220f172d7d0c87b56fd4ea72a59c3d1fb0f1cac8958122fbcf8052a314fd87ec71e64736f6c63430008210033")

// NetworkConfig holds all parameters for a specific network
type NetworkConfig struct {
	ChainID     *big.Int
	GenesisTime uint64
	GenesisHash common.Hash // Expected hash of the genesis block
	GasLimit    uint64
	BaseFee     *big.Int
	Coinbase    common.Address
	Alloc       map[common.Address]*uint256.Int
	Validators  []*consensus.Validator

	ConsensusCfg ConsensusConfig
	TxPoolCfg    TxPoolConfig
	Params       types.SystemParams
}

// TxPoolConfig holds transaction pool settings
type TxPoolConfig struct {
	GlobalSlots  uint64           // Max total transactions
	AccountSlots uint64           // Max transactions per account
	Locals       []common.Address // Addresses immune to eviction
}

// SystemParams moved to types package to avoid import cycle
// type SystemParams struct ...

// ConsensusConfig holds engine-specific parameters
type ConsensusConfig struct {
	BlockTimeout time.Duration
}

// ChainConfig returns the params.ChainConfig for this network
func (c *NetworkConfig) ChainConfig() *params.ChainConfig {
	return &params.ChainConfig{
		ChainID:                 c.ChainID,
		HomesteadBlock:          big.NewInt(0),
		DAOForkBlock:            big.NewInt(0),
		EIP150Block:             big.NewInt(0),
		EIP155Block:             big.NewInt(0),
		EIP158Block:             big.NewInt(0),
		ByzantiumBlock:          big.NewInt(0),
		ConstantinopleBlock:     big.NewInt(0),
		PetersburgBlock:         big.NewInt(0),
		IstanbulBlock:           big.NewInt(0),
		MuirGlacierBlock:        big.NewInt(0),
		BerlinBlock:             big.NewInt(0),
		LondonBlock:             big.NewInt(0), // EIP-1559 Enabled
		ArrowGlacierBlock:       nil,
		GrayGlacierBlock:        nil,
		MergeNetsplitBlock:      nil,
		ShanghaiTime:            new(uint64),   // Enable Shanghai (Time 0)
		CancunTime:              new(uint64),   // Enable Cancun (Time 0)
		TerminalTotalDifficulty: big.NewInt(0), // Force Merge at Genesis
	}
}

// GetNetworkConfig returns parameters for the requested network
func GetNetworkConfig(network string) *NetworkConfig {
	var cfg *NetworkConfig
	switch network {
	case Mainnet:
		cfg = &NetworkConfig{
			ChainID:     big.NewInt(999),
			GenesisTime: uint64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix()),
			GenesisHash: common.HexToHash("0x5fe6c0cd650a229e567b777557737345fbcf75b27fd63ed23cb21626def4c4a3"),
			GasLimit:    60000000,
			BaseFee:     big.NewInt(1000000000), // 1 Gwei Initial BaseFee
			Coinbase:    common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
			Validators:  DefaultValidators(),
			ConsensusCfg: ConsensusConfig{
				BlockTimeout: 1000 * time.Millisecond,
			},
			TxPoolCfg: TxPoolConfig{
				GlobalSlots:  5000,
				AccountSlots: 100,
				Locals:       []common.Address{common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")}, // Default User
			},
			Params: types.SystemParams{
				StakingAddr:     common.HexToAddress("0x0000000000000000000000000000000000001000"),
				RewardAddr:      common.HexToAddress("0x0000000000000000000000000000000000002000"),
				ValidatorAddr:   common.HexToAddress("0x0000000000000000000000000000000000003000"),
				RandomnessAddr:  common.HexToAddress("0x0000000000000000000000000000000000004000"),
				DefaultGasLimit: 60000000,
				DefaultBaseFee:  big.NewInt(1000000000),
			},
		}
	case Testnet:
		cfg = &NetworkConfig{
			ChainID:     big.NewInt(9999),
			GenesisTime: uint64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix()),
			GenesisHash: common.HexToHash("0x5fe6c0cd650a229e567b777557737345fbcf75b27fd63ed23cb21626def4c4a3"),
			GasLimit:    60000000,
			BaseFee:     nil, // EIP-1559 Disabled
			Coinbase:    common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
			Validators:  DefaultValidators(),
			ConsensusCfg: ConsensusConfig{
				BlockTimeout: 500 * time.Millisecond,
			},
			Params: types.SystemParams{
				StakingAddr:     common.HexToAddress("0x0000000000000000000000000000000000001000"),
				RewardAddr:      common.HexToAddress("0x0000000000000000000000000000000000002000"),
				ValidatorAddr:   common.HexToAddress("0x0000000000000000000000000000000000003000"),
				RandomnessAddr:  common.HexToAddress("0x0000000000000000000000000000000000004000"),
				DefaultGasLimit: 60000000,
				DefaultBaseFee:  big.NewInt(1000000000),
			},
		}
	case Simulation:
		cfg = &NetworkConfig{
			ChainID:     big.NewInt(1338), // Different Chain ID
			GenesisTime: uint64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix()),
			GenesisHash: common.HexToHash("0x5fe6c0cd650a229e567b777557737345fbcf75b27fd63ed23cb21626def4c4a3"), // Matches generated block
			GasLimit:    60000000,
			BaseFee:     nil, // EIP-1559 Disabled
			Coinbase:    common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
			Validators:  SimulationValidators(),
			ConsensusCfg: ConsensusConfig{
				BlockTimeout: 500 * time.Millisecond,
			},
			Params: types.SystemParams{
				StakingAddr:     common.HexToAddress("0x0000000000000000000000000000000000001000"),
				RewardAddr:      common.HexToAddress("0x0000000000000000000000000000000000002000"),
				ValidatorAddr:   common.HexToAddress("0x0000000000000000000000000000000000003000"),
				RandomnessAddr:  common.HexToAddress("0x0000000000000000000000000000000000004000"), //To Be Removed and PoH/VDF to be saved in some database and synced acrossed
				DefaultGasLimit: 60000000,
				DefaultBaseFee:  big.NewInt(1000000000),
			},
		}

	default: // Devnet / Default
		cfg = &NetworkConfig{
			ChainID:     big.NewInt(99999),
			GenesisTime: uint64(time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).Unix()),
			GenesisHash: common.HexToHash("0x5fe6c0cd650a229e567b777557737345fbcf75b27fd63ed23cb21626def4c4a3"),
			GasLimit:    60000000,
			BaseFee:     big.NewInt(1000000000), // 1 Gwei Initial BaseFee
			Coinbase:    common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"),
			Validators:  DevnetValidators(),
			ConsensusCfg: ConsensusConfig{
				BlockTimeout: 200 * time.Millisecond,
			},
			TxPoolCfg: TxPoolConfig{
				GlobalSlots:  1000000,
				AccountSlots: 50000,
				Locals:       []common.Address{common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")},
			},
			Params: types.SystemParams{
				StakingAddr:     common.HexToAddress("0x0000000000000000000000000000000000001000"),
				RewardAddr:      common.HexToAddress("0x0000000000000000000000000000000000002000"),
				ValidatorAddr:   common.HexToAddress("0x0000000000000000000000000000000000003000"),
				RandomnessAddr:  common.HexToAddress("0x0000000000000000000000000000000000004000"),
				DefaultGasLimit: 60000000,
				DefaultBaseFee:  big.NewInt(1000000000),
				VDFIterations:   1100000,
				VDFInterval:     15000,
			},
		}
	}
	cfg.Alloc = GenesisAlloc(cfg)
	return cfg
}

// DefaultValidators returns the hardcoded initial validator set
func DefaultValidators() []*consensus.Validator {
	vals := []*consensus.Validator{
		{Address: common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"), Stake: big.NewInt(100)},
		{Address: common.HexToAddress("0x96216849c49358B10257cb55b28eA603c874b05E"), Stake: big.NewInt(100)},
		{Address: common.HexToAddress("0x627306090abaB3A6e1400e9345bC60c78a8BEf57"), Stake: big.NewInt(100)},
		{Address: common.HexToAddress("0xf17f52151EbEF6C7334FAD080c5704D77216b732"), Stake: big.NewInt(100)},
	}
	populateBLS(vals)
	return vals
}

// DevnetValidators returns a single validator with keys populated for Devnet
func DevnetValidators() []*consensus.Validator {
	vals := []*consensus.Validator{
		{Address: common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"), Stake: big.NewInt(100)},
	}
	populateBLS(vals)
	return vals
}

// SimulationValidators returns 4 hardcoded validators for simulation
func SimulationValidators() []*consensus.Validator {
	vals := []*consensus.Validator{
		// 4 Fixed Keys (Same as in simulation/main.go)
		{Address: common.HexToAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"), Stake: big.NewInt(100)}, // Val 0
		{Address: common.HexToAddress("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"), Stake: big.NewInt(100)}, // Val 1
		{Address: common.HexToAddress("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"), Stake: big.NewInt(100)}, // Val 2
		{Address: common.HexToAddress("0x90F79bf6EB2c4f870365E785982E1f101E93b906"), Stake: big.NewInt(100)}, // Val 3
	}
	populateBLS(vals)
	return vals
}

// populateBLS sets placeholder BLS keys for Devnet/Simulation ONLY if they are missing.
// In a real network, validators must provide these in genesis.
func populateBLS(vals []*consensus.Validator) {
	for _, v := range vals {
		if len(v.BLSPubKey) == 0 {
			// DEV ONLY: Deterministic Generation for ease of testing
			seed := crypto.Keccak256(v.Address.Bytes())
			sk := new(big.Int).SetBytes(seed)

			var pk bls12381.G1Affine
			pk.ScalarMultiplicationBase(sk)
			pkBytes := pk.Bytes()
			v.BLSPubKey = pkBytes[:]
		}
	}
}

// DefaultChainConfig returns the default hardcoded chain configuration
func DefaultChainConfig() *params.ChainConfig {
	return &params.ChainConfig{
		ChainID:                 big.NewInt(99999),
		HomesteadBlock:          big.NewInt(0),
		DAOForkBlock:            big.NewInt(0),
		EIP150Block:             big.NewInt(0),
		EIP155Block:             big.NewInt(0),
		EIP158Block:             big.NewInt(0),
		ByzantiumBlock:          big.NewInt(0),
		ConstantinopleBlock:     big.NewInt(0),
		PetersburgBlock:         big.NewInt(0),
		IstanbulBlock:           big.NewInt(0),
		MuirGlacierBlock:        big.NewInt(0),
		BerlinBlock:             big.NewInt(0),
		LondonBlock:             big.NewInt(0), // EIP-1559 Enabled
		ArrowGlacierBlock:       nil,
		GrayGlacierBlock:        nil,
		MergeNetsplitBlock:      nil,
		ShanghaiTime:            new(uint64), // Enable Shanghai (Time 0)
		CancunTime:              new(uint64), // Enable Cancun (Time 0)
		TerminalTotalDifficulty: big.NewInt(0),
	}
}

// GenerateGenesisBlock creates the hardcoded genesis block for a config
func GenerateGenesisBlock(cfg *NetworkConfig) *types.Block {
	header := &types.Header{
		Number:     big.NewInt(0),
		Time:       cfg.GenesisTime,
		ParentHash: common.Hash{},
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

	// Token Program (Solidity Native Bridge) - Address 0x...5000
	alloc[state.TokenProgramID] = &uint256.Int{} // 0 Balance
	// We need to set Code. But Alloc is map[Address]*uint256.Int.
	// Geth's Genesis struct handles code via 'Code' field in GenesisAccount.
	// But here 'Alloc' is just the map in NetworkConfig.
	// Look at GenerateGenesisBlock. It uses 'Alloc'.
	// Wait, 'NetworkConfig.Alloc' is just 'map[common.Address]*uint256.Int'.
	// This structure doesn't support setting Code!
	// I need to check valid Geth Genesis struct.

	// Requested Allocation
	// 10,000 Zee = 10000 * 10^18
	reqAddr := common.HexToAddress("0xfc77dd2e36da5546258f6c25cf0f71d1460aaff0")
	reqAmt, _ := new(big.Int).SetString("10000000000000000000000", 10) // 10,000 * 1e18
	reqBal, _ := uint256.FromBig(reqAmt)
	alloc[reqAddr] = reqBal

	return alloc
}
