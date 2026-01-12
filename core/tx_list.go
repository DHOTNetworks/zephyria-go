package core

import (
	"fmt"
	"math/big"
	"sort"

	ethtypes "github.com/ethereum/go-ethereum/core/types"
)

// txList is a list of transactions sorted by nonce.
// It handles gap detection and replacement.
type txList struct {
	txs   *sortedTxs // Heap/Sortable
	nonce uint64     // Current expected nonce (State Nonce)
}

func newTxList(nonce uint64) *txList {
	return &txList{
		txs:   new(sortedTxs),
		nonce: nonce,
	}
}

// Add adds a tx to the list. Returns true if it replaced an old one.
// Returns error if nonce is too old.
func (l *txList) Add(tx *ethtypes.Transaction, priceBump uint64) (bool, *ethtypes.Transaction, error) {
	if tx.Nonce() < l.nonce {
		return false, nil, ErrTxNonceTooLow
	}

	// Check for replacement
	old := l.txs.Get(tx.Nonce())
	if old != nil {
		// Price bump check
		oldPrice := old.GasPrice()
		newPrice := tx.GasPrice()

		// minPrice = oldPrice * (100 + priceBump) / 100
		threshold := new(big.Int).Mul(oldPrice, big.NewInt(int64(100+priceBump)))
		threshold.Div(threshold, big.NewInt(100))

		if newPrice.Cmp(threshold) < 0 {
			return false, nil, fmt.Errorf("replacement transaction underpriced: need %v, have %v", threshold, newPrice)
		}

		l.txs.Remove(tx.Nonce())
		l.txs.Add(tx)
		return true, old, nil
	}

	l.txs.Add(tx)
	return false, nil, nil
}

// Forward advances the expected nonce, simulating block inclusion.
// Returns removed transactions (those with nonce < newNonce).
func (l *txList) Forward(newNonce uint64) []*ethtypes.Transaction {
	var removed []*ethtypes.Transaction
	l.nonce = newNonce

	// Remove now-old transactions
	// Since it's sorted, we can just pop from front until checking
	// But `sortedTxs` is a set. We filter.
	l.txs.Filter(func(tx *ethtypes.Transaction) bool {
		if tx.Nonce() < newNonce {
			removed = append(removed, tx)
			return false // Remove
		}
		return true // Keep
	})
	return removed
}

// Ready returns transactions that are executable (continuous nonces starting from l.nonce).
func (l *txList) Ready(cap int) []*ethtypes.Transaction {
	var ready []*ethtypes.Transaction
	next := l.nonce

	for _, tx := range *l.txs {
		if tx.Nonce() > next {
			break // Gap found
		}
		if tx.Nonce() == next {
			ready = append(ready, tx)
			next++
		}
		if len(ready) >= cap {
			break
		}
	}
	return ready
}

// Len returns number of txs.
func (l *txList) Len() int {
	return len(*l.txs)
}

// Empty returns true if list is empty.
func (l *txList) Empty() bool {
	return len(*l.txs) == 0
}

// sortedTxs implements sort.Interface
type sortedTxs []*ethtypes.Transaction

func (s sortedTxs) Len() int           { return len(s) }
func (s sortedTxs) Swap(i, j int)      { s[i], s[j] = s[j], s[i] }
func (s sortedTxs) Less(i, j int) bool { return s[i].Nonce() < s[j].Nonce() }

func (s *sortedTxs) Add(tx *ethtypes.Transaction) {
	*s = append(*s, tx)
	sort.Sort(s)
}

func (s *sortedTxs) Get(nonce uint64) *ethtypes.Transaction {
	for _, tx := range *s {
		if tx.Nonce() == nonce {
			return tx
		}
	}
	return nil
}

func (s *sortedTxs) Remove(nonce uint64) {
	// Find and remove
	for i, tx := range *s {
		if tx.Nonce() == nonce {
			*s = append((*s)[:i], (*s)[i+1:]...)
			return
		}
	}
}

// Filter modifies slice in place
func (s *sortedTxs) Filter(fn func(*ethtypes.Transaction) bool) {
	n := 0
	for _, x := range *s {
		if fn(x) {
			(*s)[n] = x
			n++
		}
	}
	*s = (*s)[:n]
}
