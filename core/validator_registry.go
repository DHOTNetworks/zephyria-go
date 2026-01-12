package core

import (
	"fmt"
	"math/big"

	"zephyria/state"
	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rlp"
	"github.com/holiman/uint256"
)

// OnChainValidatorRegistry manages the on-chain validator state
type OnChainValidatorRegistry struct {
	stakingAddr   common.Address
	validatorAddr common.Address
	constants     *types.StakingConstants
}

// NewOnChainValidatorRegistry creates a new validator registry
func NewOnChainValidatorRegistry(stakingAddr, validatorAddr common.Address) *OnChainValidatorRegistry {
	return &OnChainValidatorRegistry{
		stakingAddr:   stakingAddr,
		validatorAddr: validatorAddr,
		constants:     types.DefaultStakingConstants(),
	}
}

// Storage key helpers
func (r *OnChainValidatorRegistry) validatorInfoKey(addr common.Address) common.Hash {
	return crypto.Keccak256Hash(addr.Bytes(), []byte("INFO"))
}

func (r *OnChainValidatorRegistry) validatorCountKey() common.Hash {
	return common.Hash{} // Slot 0
}

func (r *OnChainValidatorRegistry) validatorIndexKey(index uint64) common.Hash {
	return common.BigToHash(new(big.Int).SetUint64(index))
}

func (r *OnChainValidatorRegistry) unbondingQueueKey(addr common.Address, index uint64) common.Hash {
	return crypto.Keccak256Hash(addr.Bytes(), []byte("UNBOND"), common.BigToHash(new(big.Int).SetUint64(index)).Bytes())
}

func (r *OnChainValidatorRegistry) unbondingCountKey(addr common.Address) common.Hash {
	return crypto.Keccak256Hash(addr.Bytes(), []byte("UNBOND_COUNT"))
}

func (r *OnChainValidatorRegistry) slashingRecordKey(slashID uint64) common.Hash {
	return crypto.Keccak256Hash([]byte("SLASH"), common.BigToHash(new(big.Int).SetUint64(slashID)).Bytes())
}

func (r *OnChainValidatorRegistry) slashingCountKey() common.Hash {
	return crypto.Keccak256Hash([]byte("SLASH_COUNT"))
}

// encodeValidatorInfo encodes validator info into storage slots
func (r *OnChainValidatorRegistry) encodeValidatorInfo(info *types.ValidatorInfo) []byte {
	data, _ := rlp.EncodeToBytes(info)
	return data
}

// decodeValidatorInfo decodes validator info from storage
func (r *OnChainValidatorRegistry) decodeValidatorInfo(data []byte) (*types.ValidatorInfo, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("no validator info found")
	}

	var info types.ValidatorInfo
	if err := rlp.DecodeBytes(data, &info); err != nil {
		return nil, err
	}
	return &info, nil
}

// GetValidatorInfo retrieves validator information from state
func (r *OnChainValidatorRegistry) GetValidatorInfo(statedb *state.StateDB, addr common.Address) (*types.ValidatorInfo, error) {
	key := r.validatorInfoKey(addr)
	data := statedb.GetState(r.stakingAddr, key).Bytes()

	if len(data) == 0 || (data[0] == 0 && len(data) == 32) {
		return nil, fmt.Errorf("validator not found")
	}

	return r.decodeValidatorInfo(data)
}

// SetValidatorInfo stores validator information to state
func (r *OnChainValidatorRegistry) SetValidatorInfo(statedb *state.StateDB, info *types.ValidatorInfo) error {
	key := r.validatorInfoKey(info.Address)
	data := r.encodeValidatorInfo(info)

	// Store RLP-encoded data
	// For simplicity, we'll store the hash of the data and the data itself in a derived key
	dataHash := crypto.Keccak256Hash(data)
	statedb.SetState(r.stakingAddr, key, dataHash)

	// Store actual data in a derived slot
	dataKey := crypto.Keccak256Hash(key.Bytes(), []byte("DATA"))
	// Split data into 32-byte chunks
	for i := 0; i < len(data); i += 32 {
		end := i + 32
		if end > len(data) {
			end = len(data)
		}
		chunk := make([]byte, 32)
		copy(chunk, data[i:end])

		chunkKey := crypto.Keccak256Hash(dataKey.Bytes(), common.BigToHash(new(big.Int).SetUint64(uint64(i/32))).Bytes())
		statedb.SetState(r.stakingAddr, chunkKey, common.BytesToHash(chunk))
	}

	return nil
}

// RegisterValidator registers a new validator
func (r *OnChainValidatorRegistry) RegisterValidator(
	statedb *state.StateDB,
	addr common.Address,
	stake *big.Int,
	blsPubKey []byte,
	commission uint16,
	blockNum uint64,
) error {
	// Validate inputs
	if stake.Cmp(r.constants.MinStake) < 0 {
		return fmt.Errorf("stake below minimum: %s < %s", stake.String(), r.constants.MinStake.String())
	}

	if stake.Cmp(r.constants.MaxStake) > 0 {
		return fmt.Errorf("stake above maximum: %s > %s", stake.String(), r.constants.MaxStake.String())
	}

	if len(blsPubKey) != 48 {
		return fmt.Errorf("invalid BLS public key length: %d", len(blsPubKey))
	}

	if commission > 10000 {
		return fmt.Errorf("commission rate too high: %d > 10000", commission)
	}

	// Check if validator already exists
	existing, _ := r.GetValidatorInfo(statedb, addr)
	if existing != nil {
		return fmt.Errorf("validator already registered")
	}

	// Check validator count
	countKey := r.validatorCountKey()
	count := statedb.GetState(r.validatorAddr, countKey).Big().Uint64()
	if count >= r.constants.MaxValidators {
		return fmt.Errorf("maximum validators reached: %d", count)
	}

	// Create validator info
	info := &types.ValidatorInfo{
		Address:         addr,
		Stake:           new(big.Int).Set(stake),
		Status:          types.ValidatorActive,
		BLSPubKey:       blsPubKey,
		Commission:      commission,
		ActivationBlock: blockNum,
		SlashCount:      0,
		TotalRewards:    big.NewInt(0),
	}

	// Store validator info
	if err := r.SetValidatorInfo(statedb, info); err != nil {
		return err
	}

	// Update validator count and index
	newCount := count + 1
	statedb.SetState(r.validatorAddr, countKey, common.BigToHash(new(big.Int).SetUint64(newCount)))

	// Store index -> address mapping
	indexKey := r.validatorIndexKey(newCount)
	statedb.SetState(r.validatorAddr, indexKey, common.BytesToHash(addr.Bytes()))

	// Store address -> index mapping
	addrKey := common.BytesToHash(addr.Bytes())
	statedb.SetState(r.validatorAddr, addrKey, common.BigToHash(new(big.Int).SetUint64(newCount)))

	fmt.Printf("[Validator] Registered: %s | Stake: %s | BLS: %x...\n",
		addr.Hex(), stake.String(), blsPubKey[:8])

	return nil
}

// AddStake increases a validator's stake
func (r *OnChainValidatorRegistry) AddStake(statedb *state.StateDB, addr common.Address, amount *big.Int) error {
	info, err := r.GetValidatorInfo(statedb, addr)
	if err != nil {
		return err
	}

	newStake := new(big.Int).Add(info.Stake, amount)
	if newStake.Cmp(r.constants.MaxStake) > 0 {
		return fmt.Errorf("stake would exceed maximum")
	}

	info.Stake = newStake
	return r.SetValidatorInfo(statedb, info)
}

// RequestUnstake creates an unbonding request
func (r *OnChainValidatorRegistry) RequestUnstake(
	statedb *state.StateDB,
	addr common.Address,
	amount *big.Int,
	blockNum uint64,
) (uint64, error) {
	info, err := r.GetValidatorInfo(statedb, addr)
	if err != nil {
		return 0, err
	}

	if amount.Cmp(info.Stake) > 0 {
		return 0, fmt.Errorf("unstake amount exceeds stake")
	}

	// Calculate unlock block
	unlockBlock := blockNum + r.constants.UnbondingPeriod

	// Create unbonding request
	request := &types.UnbondingRequest{
		Amount:       new(big.Int).Set(amount),
		UnlockBlock:  unlockBlock,
		RequestBlock: blockNum,
	}

	// Get current unbonding count for this validator
	countKey := r.unbondingCountKey(addr)
	count := statedb.GetState(r.stakingAddr, countKey).Big().Uint64()

	// Store unbonding request
	queueKey := r.unbondingQueueKey(addr, count)
	requestData, _ := rlp.EncodeToBytes(request)
	statedb.SetState(r.stakingAddr, queueKey, common.BytesToHash(requestData))

	// Increment count
	statedb.SetState(r.stakingAddr, countKey, common.BigToHash(new(big.Int).SetUint64(count+1)))

	// Update validator stake and status
	info.Stake = new(big.Int).Sub(info.Stake, amount)
	if info.Stake.Sign() == 0 {
		info.Status = types.ValidatorUnbonding
	}

	if err := r.SetValidatorInfo(statedb, info); err != nil {
		return 0, err
	}

	fmt.Printf("[Validator] Unstake requested: %s | Amount: %s | Unlock: %d\n",
		addr.Hex(), amount.String(), unlockBlock)

	return unlockBlock, nil
}

// ProcessMatureUnstakes processes all mature unbonding requests
func (r *OnChainValidatorRegistry) ProcessMatureUnstakes(statedb *state.StateDB, blockNum uint64) int {
	processed := 0

	// This is a simplified implementation
	// In production, you'd want to maintain a more efficient queue structure
	// For now, we'll iterate through all validators and check their unbonding queues

	countKey := r.validatorCountKey()
	validatorCount := statedb.GetState(r.validatorAddr, countKey).Big().Uint64()

	for i := uint64(1); i <= validatorCount; i++ {
		indexKey := r.validatorIndexKey(i)
		addrHash := statedb.GetState(r.validatorAddr, indexKey)
		if addrHash == (common.Hash{}) {
			continue
		}

		addr := common.BytesToAddress(addrHash.Bytes())
		processed += r.processValidatorUnbonding(statedb, addr, blockNum)
	}

	return processed
}

func (r *OnChainValidatorRegistry) processValidatorUnbonding(statedb *state.StateDB, addr common.Address, blockNum uint64) int {
	processed := 0

	countKey := r.unbondingCountKey(addr)
	count := statedb.GetState(r.stakingAddr, countKey).Big().Uint64()

	for i := uint64(0); i < count; i++ {
		queueKey := r.unbondingQueueKey(addr, i)
		requestData := statedb.GetState(r.stakingAddr, queueKey).Bytes()

		if len(requestData) == 0 {
			continue
		}

		var request types.UnbondingRequest
		if err := rlp.DecodeBytes(requestData, &request); err != nil {
			continue
		}

		if blockNum >= request.UnlockBlock {
			// Refund the validator
			amount256 := uint256.MustFromBig(request.Amount)
			statedb.AddBalance(addr, amount256, 0)

			// Clear the unbonding request
			statedb.SetState(r.stakingAddr, queueKey, common.Hash{})

			processed++

			fmt.Printf("[Validator] Unstake completed: %s | Amount: %s\n",
				addr.Hex(), request.Amount.String())
		}
	}

	return processed
}

// SlashValidator slashes a validator for misbehavior
func (r *OnChainValidatorRegistry) SlashValidator(
	statedb *state.StateDB,
	addr common.Address,
	slashType types.SlashingType,
	evidence []byte,
	blockNum uint64,
	reporter common.Address,
) error {
	info, err := r.GetValidatorInfo(statedb, addr)
	if err != nil {
		return err
	}

	if info.Status == types.ValidatorSlashed {
		return fmt.Errorf("validator already slashed")
	}

	// Calculate slash amount (50% of stake)
	slashAmount := new(big.Int).Mul(info.Stake, big.NewInt(int64(r.constants.SlashPercentage)))
	slashAmount.Div(slashAmount, big.NewInt(100))

	// Update validator info
	info.Stake = new(big.Int).Sub(info.Stake, slashAmount)
	info.Status = types.ValidatorSlashed
	info.SlashCount++

	if err := r.SetValidatorInfo(statedb, info); err != nil {
		return err
	}

	// Create slashing record
	slashCountKey := r.slashingCountKey()
	slashID := statedb.GetState(r.stakingAddr, slashCountKey).Big().Uint64()

	record := &types.SlashingRecord{
		ValidatorAddr: addr,
		SlashType:     slashType,
		Evidence:      evidence,
		SlashAmount:   slashAmount,
		BlockNumber:   blockNum,
		Reporter:      reporter,
	}

	recordKey := r.slashingRecordKey(slashID)
	recordData, _ := rlp.EncodeToBytes(record)
	statedb.SetState(r.stakingAddr, recordKey, common.BytesToHash(recordData))

	// Increment slash count
	statedb.SetState(r.stakingAddr, slashCountKey, common.BigToHash(new(big.Int).SetUint64(slashID+1)))

	// Burn slashed funds (or send to treasury)
	// For now, we'll just reduce the stake without refunding

	fmt.Printf("[Validator] SLASHED: %s | Type: %s | Amount: %s\n",
		addr.Hex(), slashType.String(), slashAmount.String())

	return nil
}

// GetAllActiveValidators returns all active validators
func (r *OnChainValidatorRegistry) GetAllActiveValidators(statedb *state.StateDB) ([]*types.ValidatorInfo, error) {
	countKey := r.validatorCountKey()
	count := statedb.GetState(r.validatorAddr, countKey).Big().Uint64()

	validators := make([]*types.ValidatorInfo, 0, count)

	for i := uint64(1); i <= count; i++ {
		indexKey := r.validatorIndexKey(i)
		addrHash := statedb.GetState(r.validatorAddr, indexKey)

		if addrHash == (common.Hash{}) {
			continue
		}

		addr := common.BytesToAddress(addrHash.Bytes())
		info, err := r.GetValidatorInfo(statedb, addr)
		if err != nil {
			continue
		}

		if info.Status == types.ValidatorActive {
			validators = append(validators, info)
		}
	}

	return validators, nil
}

// UpdateValidator updates validator metadata or commission
func (r *OnChainValidatorRegistry) UpdateValidator(
	statedb *state.StateDB,
	addr common.Address,
	name string,
	website string,
	commission *uint16,
) error {
	info, err := r.GetValidatorInfo(statedb, addr)
	if err != nil {
		return err
	}

	if name != "" {
		info.Name = name
	}
	if website != "" {
		info.Website = website
	}
	if commission != nil {
		if *commission > 10000 {
			return fmt.Errorf("commission rate too high")
		}
		info.Commission = *commission
	}

	return r.SetValidatorInfo(statedb, info)
}

// GetUnbondingRequests returns all unbonding requests for a validator
func (r *OnChainValidatorRegistry) GetUnbondingRequests(statedb *state.StateDB, addr common.Address) ([]*types.UnbondingRequest, error) {
	countKey := r.unbondingCountKey(addr)
	count := statedb.GetState(r.stakingAddr, countKey).Big().Uint64()

	requests := make([]*types.UnbondingRequest, 0, count)

	for i := uint64(0); i < count; i++ {
		queueKey := r.unbondingQueueKey(addr, i)
		requestData := statedb.GetState(r.stakingAddr, queueKey).Bytes()

		if len(requestData) == 0 {
			continue
		}

		var request types.UnbondingRequest
		if err := rlp.DecodeBytes(requestData, &request); err != nil {
			continue
		}

		requests = append(requests, &request)
	}

	return requests, nil
}
