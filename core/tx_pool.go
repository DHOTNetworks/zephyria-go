package core

import (
	"errors"
	"fmt"
	"os"
	"sync"
	"time"
	"zephyria/state"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

var (
	ErrTxKnown       = errors.New("transaction already known")
	ErrTxNonceTooLow = errors.New("nonce too low")
	ErrOversized     = errors.New("transaction too large")
	ErrInsuffFunds   = errors.New("insufficient funds")
)

// TxPool manages transactions using a per-account nonce-sorted list.
type TxPool struct {
	mu sync.RWMutex

	config      *NetworkConfig
	chainConfig *params.ChainConfig
	state       func() *state.StateDB

	// Notifications
	notifyCh chan struct{}

	accounts map[common.Address]*txList
	all      map[common.Hash]*ethtypes.Transaction
	txAges   map[common.Hash]time.Time // Gap 5.2: Track insertion time
}

func NewTxPool(cfg *NetworkConfig) *TxPool {
	pool := &TxPool{
		config:      cfg,
		chainConfig: cfg.ChainConfig(),
		accounts:    make(map[common.Address]*txList),
		all:         make(map[common.Hash]*ethtypes.Transaction),
		txAges:      make(map[common.Hash]time.Time),
	}
	// Start Eviction Loop
	go pool.evictionLoop()
	return pool
}

func (pool *TxPool) evictionLoop() {
	ticker := time.NewTicker(5 * time.Minute)
	for range ticker.C {
		pool.evictExpired()
	}
}

func (pool *TxPool) evictExpired() {
	pool.mu.Lock()
	defer pool.mu.Unlock()

	now := time.Now()
	// 1 Hour TTL
	ttl := time.Hour

	for hash, age := range pool.txAges {
		if now.Sub(age) > ttl {
			// Evict
			if tx, ok := pool.all[hash]; ok {
				signer := ethtypes.LatestSigner(pool.chainConfig)
				sender, _ := ethtypes.Sender(signer, tx) // Should be safe if already in pool
				if list, ok := pool.accounts[sender]; ok {
					list.txs.Remove(tx.Nonce())
					if list.Empty() {
						delete(pool.accounts, sender)
					}
				}
				delete(pool.all, hash)
				delete(pool.txAges, hash)
				fmt.Fprintf(os.Stderr, "[TxPool] Evicted expired tx %s (Age: %v)\n", hash.Hex(), now.Sub(age))
			} else {
				// Orphaned age record
				delete(pool.txAges, hash)
			}
		}
	}
}

// Subscribe allows a component to receive wake-up signals
func (pool *TxPool) Subscribe(ch chan struct{}) {
	pool.mu.Lock()
	defer pool.mu.Unlock()
	pool.notifyCh = ch
}

func (pool *TxPool) SetStateProvider(fn func() *state.StateDB) {
	pool.state = fn
}

// Add checks validity, state, and adds to the account's list.
func (pool *TxPool) Add(tx *ethtypes.Transaction) (bool, error) {
	pool.mu.Lock()
	defer pool.mu.Unlock()

	hash := tx.Hash()
	if _, ok := pool.all[hash]; ok {
		return false, ErrTxKnown
	}

	// Track Age
	pool.txAges[hash] = time.Now()

	// 1. Validation
	if tx.Size() > 128*1024 {
		return false, ErrOversized
	}
	signer := ethtypes.LatestSigner(pool.chainConfig)
	sender, err := ethtypes.Sender(signer, tx)
	if err != nil {
		return false, fmt.Errorf("invalid sender: %v", err)
	}

	// 2. State & Nonce Check
	stateNonce := uint64(0)
	if pool.state != nil {
		st := pool.state()
		if st != nil {
			stateNonce = st.GetNonce(sender)
			if tx.Nonce() < stateNonce {
				return false, ErrTxNonceTooLow
			}
			// Strict balance check for future:
			// For unrelated txs, we might not want to check strict balance yet if they are queued?
			// But for DoS, let's check current balance covers at least this tx cost.
			bal := st.GetBalance(sender)
			cost := tx.Cost()
			cost256, _ := uint256.FromBig(cost)
			if bal.Cmp(cost256) < 0 {
				return false, ErrInsuffFunds
			}
		}
	}

	// 3. Add to Account List
	// Enforce AccountSlots Limit
	list, ok := pool.accounts[sender]
	if !ok {
		list = newTxList(stateNonce)
		pool.accounts[sender] = list
	} else {
		// Update list's view of state
		if stateNonce > list.nonce {
			removed := list.Forward(stateNonce)
			for _, r := range removed {
				delete(pool.all, r.Hash())
			}
		}
	}

	// Check Account Limit (unless local)
	if !pool.isLocal(sender) && uint64(list.Len()) >= pool.config.TxPoolCfg.AccountSlots {
		return false, errors.New("tx pool: account limit exceeded")
	}

	replaced, oldTx, err := list.Add(tx, 10)
	if err != nil {
		return false, err
	}

	if replaced && oldTx != nil {
		delete(pool.all, oldTx.Hash())
	}
	pool.all[hash] = tx

	// 4. Global Limit Check (Eviction / Rejection)
	// If pool is full:
	// - If Local: Allow (Immunity).
	// - If Not Local: Reject (Simple DoS protection).
	// Real Geth would evict the "cheapest" transaction from the pool.
	// We simplify: First-Come-First-Served with VIP access for Locals.
	currentSize := uint64(len(pool.all))
	if currentSize >= pool.config.TxPoolCfg.GlobalSlots {
		if !pool.isLocal(sender) {
			// Revert the addition if we are over limit and not local
			// (We already added it above, need to back out?
			//  Actually we should check BEFORE adding.
			//  But adding handles replacement logic...
			//  If replacement happened, count didn't increase.
			//  If verified replacement, we are fine.
			//  But if new, we are +1.
			//  Let's check before `list.Add`?
			//  No, strict check here:
			//  If we grew and are over limit:
			list.txs.Remove(tx.Nonce()) // Remove the one we just added
			delete(pool.all, hash)
			return false, errors.New("tx pool: global limit exceeded")
		}
	}

	if pool.notifyCh != nil {
		select {
		case pool.notifyCh <- struct{}{}:
		default:
		}
	}
	fmt.Fprintf(os.Stderr, "[TxPool] Added tx from %s, nonce %d (Pending: %d)\n", sender.Hex(), tx.Nonce(), len(pool.all))

	return true, nil
}

func (pool *TxPool) isLocal(addr common.Address) bool {
	for _, local := range pool.config.TxPoolCfg.Locals {
		if local == addr {
			return true
		}
	}
	return false
}

// evict stub not needed if we reject.

// Get returns string representation of limits (custom helper)
func (pool *TxPool) Limits() string {
	return fmt.Sprintf("Global: %d, Account: %d", pool.config.TxPoolCfg.GlobalSlots, pool.config.TxPoolCfg.AccountSlots)
}

// Get returns a transaction by hash.
func (pool *TxPool) Get(hash common.Hash) *ethtypes.Transaction {
	pool.mu.RLock()
	defer pool.mu.RUnlock()
	return pool.all[hash]
}

// Pending returns ALL executable transactions (nonce-continuous from state).
func (pool *TxPool) Pending() []*ethtypes.Transaction {
	pool.mu.RLock()
	defer pool.mu.RUnlock()

	var batch []*ethtypes.Transaction
	for _, list := range pool.accounts {
		// Get executable txs (nonce == list.nonce, +1, +2...)
		// 4096 is safety cap per account to prevent massive aggregation
		ready := list.Ready(4096)
		batch = append(batch, ready...)
	}
	return batch
}

// Stats returns counts.
func (pool *TxPool) Stats() (int, int) {
	pool.mu.RLock()
	defer pool.mu.RUnlock()

	pending := 0
	queued := 0

	for _, list := range pool.accounts {
		ready := len(list.Ready(100000))
		total := list.Len()
		pending += ready
		queued += (total - ready)
	}
	return pending, queued
}

// Remove removes transactions.
func (pool *TxPool) Remove(txs []*ethtypes.Transaction) {
	pool.mu.Lock()
	defer pool.mu.Unlock()

	// Usually called after block import.
	// We should just update accounts nonces?
	// But we might want explicit removal.
	// Efficient way: Update State Nonce for affected accounts.
	// Since we don't have new state here easily, we iterate txs.

	// Actually, the Node calls Remove.
	// If Node just calls pool.Reset(stateNonce), that's better.
	// But let's stick to interface.

	for _, tx := range txs {
		if _, ok := pool.all[tx.Hash()]; ok {
			delete(pool.all, tx.Hash())
			delete(pool.txAges, tx.Hash()) // Clear age
			// Remove from list?
			// This is inefficient to find sender and remove one by one.
			// Ideally we rely on Stale/Forward logic.
			// But let's do safe cleanup.
			signer := ethtypes.LatestSigner(pool.chainConfig)
			sender, _ := ethtypes.Sender(signer, tx)
			if list, ok := pool.accounts[sender]; ok {
				list.txs.Remove(tx.Nonce())
			}
		}
	}
}

// StateUpdate should be called when block is imported to advance nonces.
func (pool *TxPool) StateUpdate(stateProvider func() *state.StateDB) {
	pool.mu.Lock()
	defer pool.mu.Unlock()

	pool.state = stateProvider
	st := pool.state()
	if st == nil {
		return
	}

	for addr, list := range pool.accounts {
		nonce := st.GetNonce(addr)
		if nonce > list.nonce {
			removed := list.Forward(nonce)
			for _, tx := range removed {
				delete(pool.all, tx.Hash())
				delete(pool.txAges, tx.Hash())
			}
		}
		// Clean up empty accounts to prevent memory leak
		if list.Empty() {
			delete(pool.accounts, addr)
		}
	}
}

// Content returns pending txs (alias).
func (pool *TxPool) Content() []*ethtypes.Transaction {
	return pool.Pending()
}
