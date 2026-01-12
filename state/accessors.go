package state

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

// Address to Stem/Key Mapping
// We use 31 bytes of hash as stem.
// Suffixes:
// 0x00: Nonce (re-encoded)
// 0x01: Balance
// 0x02: CodeHash
// Storage: Different stem.

func AccountStem(addr common.Address) []byte {
	h := crypto.Keccak256Hash(addr.Bytes())
	return h[:31]
}

func NonceKey(addr common.Address) []byte {
	return append(AccountStem(addr), 0x00)
}

func BalanceKey(addr common.Address) []byte {
	return append(AccountStem(addr), 0x01)
}

func CodeHashKey(addr common.Address) []byte {
	return append(AccountStem(addr), 0x02)
}

func ProgramKey(addr common.Address) []byte {
	return append(AccountStem(addr), 0x03)
}

// Prefetch warms up the cache for the given addresses.
func (s *StateDB) Prefetch(addrs []common.Address) {
	s.rwMutex.RLock()
	defer s.rwMutex.RUnlock()

	for _, addr := range addrs {
		// Just accessing the values triggers the underlying tree/DB load
		s.getVerkleValue(NonceKey(addr))
		s.getVerkleValue(BalanceKey(addr))
		s.getVerkleValue(CodeHashKey(addr))
		s.getVerkleValue(ProgramKey(addr))
	}
}

// Core EVM Methods

func (s *StateDB) CreateAccount(addr common.Address) {
	// No-op in Verkle usually, just setting values creates it.
}

func (s *StateDB) CreateContract(addr common.Address) {
	// No-op for PoC
}

// addBalance is a helper to update an account's balance.
func (s *StateDB) addBalance(addr common.Address, amount *uint256.Int) uint256.Int {
	cur := s.GetBalance(addr)
	newBal := new(uint256.Int).Add(cur, amount)
	s.SetBalance(addr, newBal, tracing.BalanceChangeReason(0)) // Reason is set by caller
	return *newBal
}

// AddBalance adds to the balance of an account.
func (s *StateDB) AddBalance(addr common.Address, amount *uint256.Int, reason tracing.BalanceChangeReason) uint256.Int {
	return s.addBalance(addr, amount)
}

// AddBalanceReward adds a block reward (convenience wrapper).
func (s *StateDB) AddBalanceReward(addr common.Address, amount *uint256.Int) {
	s.AddBalance(addr, amount, tracing.BalanceChangeReason(0))
}

func (s *StateDB) SubBalance(addr common.Address, amount *uint256.Int, reason tracing.BalanceChangeReason) uint256.Int {
	neg := new(uint256.Int).Neg(amount)
	return s.addBalance(addr, neg)
}

func (s *StateDB) GetBalance(addr common.Address) *uint256.Int {
	val := s.getVerkleValue(BalanceKey(addr))
	if len(val) == 0 {
		return uint256.NewInt(0)
	}
	res := new(uint256.Int)
	res.SetBytes(val)
	return res
}

func (s *StateDB) SetBalance(addr common.Address, amount *uint256.Int, reason tracing.BalanceChangeReason) {
	s.setVerkleValue(BalanceKey(addr), amount.Bytes())
}

func (s *StateDB) GetNonce(addr common.Address) uint64 {
	val := s.getVerkleValue(NonceKey(addr))
	if len(val) == 0 {
		return 0
	}
	return new(big.Int).SetBytes(val).Uint64()
}

func (s *StateDB) SetNonce(addr common.Address, nonce uint64, reason tracing.NonceChangeReason) {
	s.setVerkleValue(NonceKey(addr), big.NewInt(int64(nonce)).Bytes())
}

func (s *StateDB) GetCodeHash(addr common.Address) common.Hash {
	val := s.getVerkleValue(CodeHashKey(addr))
	if len(val) == 0 {
		return common.Hash{}
	}
	return common.BytesToHash(val)
}

func (s *StateDB) GetCode(addr common.Address) []byte {
	// Aquarius: Check for linked Program Account
	// Safety: Ensure we don't recurse on the same address or the ProgramID itself.
	if prog := s.GetProgramAddress(addr); prog != (common.Address{}) && prog != addr {
		return s.GetCode(prog)
	}

	hash := s.GetCodeHash(addr)
	if len(hash) == 0 || hash == types.EmptyCodeHash {
		return nil
	}
	if code, ok := s.code[hash]; ok {
		return code
	}
	// Check parents (Overlay support)
	curr := s.parent
	for curr != nil {
		if code, ok := curr.code[hash]; ok {
			return code
		}
		curr = curr.parent
	}

	// Try DB
	if s.db != nil {
		dbKey := append([]byte("c"), hash.Bytes()...)
		if code, err := s.db.Get(dbKey, nil); err == nil {
			s.code[hash] = code
			return code
		}
	}
	return nil
}

func (s *StateDB) SetCode(addr common.Address, code []byte, reason tracing.CodeChangeReason) []byte {
	h := crypto.Keccak256Hash(code)
	s.setVerkleValue(CodeHashKey(addr), h.Bytes())
	s.code[h] = code
	return code
}

func (s *StateDB) GetProgramAddress(addr common.Address) common.Address {
	val := s.getVerkleValue(ProgramKey(addr))
	if len(val) == 0 {
		return common.Address{}
	}
	return common.BytesToAddress(val)
}

func (s *StateDB) SetProgramAddress(addr common.Address, program common.Address) {
	s.setVerkleValue(ProgramKey(addr), program.Bytes())
}

func (s *StateDB) GetCodeSize(addr common.Address) int {
	return len(s.GetCode(addr))
}

// GetLogs returns the logs for a specific transaction hash.
func (s *StateDB) GetLogs(txHash common.Hash) []*types.Log {
	return s.logs[txHash]
}

// Storage
// Key = Hash(Addr ++ Key) for simplicity in PoC
func StorageKey(addr common.Address, key common.Hash) []byte {
	input := append(addr.Bytes(), key.Bytes()...)
	return crypto.Keccak256(input) // 32 bytes
}

func (s *StateDB) GetState(addr common.Address, key common.Hash) common.Hash {
	// Verkle requires 32 byte key.
	// EIP-4762: storage slots are grouped.
	// PoC: Just map H(addr, key) -> Value.
	sk := StorageKey(addr, key)
	val := s.getVerkleValue(sk)

	if len(val) > 0 {
		return common.BytesToHash(val)
	}

	// Aquarius State Inheritance (Read-Through)
	// If value is missing in Data Account, check the Program Account (Global Config).
	// This allows "Owner" or "Fees" set on the Contract to be visible to all Data Shards.
	if prog := s.GetProgramAddress(addr); prog != (common.Address{}) {
		// Prevent infinite recursion if Program points to itself (shouldn't happen but safe)
		if prog != addr {
			return s.GetState(prog, key)
		}
	}

	return common.Hash{}
}

func (s *StateDB) GetStateAndCommittedState(addr common.Address, key common.Hash) (common.Hash, common.Hash) {
	val := s.GetState(addr, key)
	// For PoC simplification, return current value as committed value found at start of tx scope.
	return val, val
}

// GetStorageRoot returns the root hash of the storage trie of the account.
// In Verkle, storage is part of the main tree, so this concept is different.
// We return empty hash for interface compatibility or PoC.
func (s *StateDB) GetStorageRoot(addr common.Address) common.Hash {
	return common.Hash{}
}

func (s *StateDB) GetTransientState(addr common.Address, key common.Hash) common.Hash {
	if s.transientStorage == nil {
		return common.Hash{}
	}
	if storage, ok := s.transientStorage[addr]; ok {
		return storage[key]
	}
	return common.Hash{}
}

func (s *StateDB) SetTransientState(addr common.Address, key, value common.Hash) {
	if s.transientStorage == nil {
		s.transientStorage = make(map[common.Address]map[common.Hash]common.Hash)
	}
	if _, ok := s.transientStorage[addr]; !ok {
		s.transientStorage[addr] = make(map[common.Hash]common.Hash)
	}
	s.transientStorage[addr][key] = value
}

func (s *StateDB) SetState(addr common.Address, key common.Hash, value common.Hash) common.Hash {
	oldVal := s.GetState(addr, key) // get old for return (simulated)
	sk := StorageKey(addr, key)
	s.setVerkleValue(sk, value.Bytes())
	return oldVal
}

// Boilerplate stubs for StateDB interface

func (s *StateDB) SelfDestruct(addr common.Address) uint256.Int {
	// Return balance destroyed
	bal := s.GetBalance(addr)
	// tracing.BalanceChangeReason might be int or checking constants.
	// Trying unsafe cast or reasonable guess.
	// Recent Geth: it is type BalanceChangeReason uint8
	s.SetBalance(addr, uint256.NewInt(0), tracing.BalanceChangeReason(0))
	return *bal
}
func (s *StateDB) SelfDestruct6780(addr common.Address) (uint256.Int, bool) {
	// EIP-6780 behavior: only destroy if created in same tx.
	// For PoC: treat same as SelfDestruct or no-op/clearing.
	return s.SelfDestruct(addr), true
}

func (s *StateDB) HasSelfDestructed(addr common.Address) bool { return false }
func (s *StateDB) Suicide(addr common.Address) bool           { return true } // Legacy support if needed
func (s *StateDB) HasSuicided(addr common.Address) bool       { return false }
func (s *StateDB) Exist(addr common.Address) bool             { return true }
func (s *StateDB) Empty(addr common.Address) bool {
	return s.GetBalance(addr).Sign() == 0 && s.GetNonce(addr) == 0 && len(s.GetCode(addr)) == 0
}
func (s *StateDB) Prepare(rules params.Rules, sender, coinbase common.Address, dst *common.Address, precompiles []common.Address, list types.AccessList) {
	if rules.IsBerlin {
		s.accessList = newAccessList()
		s.AddAddressToAccessList(sender)
		s.AddAddressToAccessList(coinbase)
		if dst != nil {
			s.AddAddressToAccessList(*dst)
			// If it's a create transaction, the destination will be added inside the EVM
		}
		for _, addr := range precompiles {
			s.AddAddressToAccessList(addr)
		}
		for _, el := range list {
			s.AddAddressToAccessList(el.Address)
			for _, key := range el.StorageKeys {
				s.AddSlotToAccessList(el.Address, key)
			}
		}
	}
}

func (s *StateDB) AddressInAccessList(addr common.Address) bool {
	return s.accessList.ContainsAddress(addr)
}

func (s *StateDB) SlotInAccessList(addr common.Address, slot common.Hash) (addressOk bool, slotOk bool) {
	return s.accessList.Contains(addr, slot)
}

// Access List methods wrapper need internal accessList methods exposed or moved
// We can move AddAddressToAccessList wrappers here too if they exist in StateDB
func (s *StateDB) AddAddressToAccessList(addr common.Address) {
	if s.accessList != nil {
		s.accessList.AddAddress(addr)
	}
}

func (s *StateDB) AddSlotToAccessList(addr common.Address, slot common.Hash) {
	if s.accessList != nil {
		s.accessList.AddSlot(addr, slot)
	}
}
