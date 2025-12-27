package core

import (
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

// schedule groups transactions into "waves". Transactions in the same wave are independent.
func (e *Executor) schedule(txs []*types.Transaction) [][]*types.Transaction {
	var waves [][]*types.Transaction

	// Pending transactions that haven't been scheduled
	queue := make([]*types.Transaction, len(txs))
	copy(queue, txs)

	signer := types.LatestSigner(e.config)

	for len(queue) > 0 {
		var currentWave []*types.Transaction
		var nextQueue []*types.Transaction

		touched := make(map[common.Address]bool)

		for _, tx := range queue {
			sender, _ := types.Sender(signer, tx) // Cached
			recipient := common.Address{}
			if tx.To() != nil {
				recipient = *tx.To()
			}

			// Check conflicts
			if touched[sender] || (tx.To() != nil && touched[recipient]) {
				// Conflict: defer to next wave
				nextQueue = append(nextQueue, tx)
			} else {
				// Independent: add to wave
				currentWave = append(currentWave, tx)
				touched[sender] = true
				if tx.To() != nil {
					touched[recipient] = true
				}
			}
		}

		if len(currentWave) == 0 {
			// Should not happen unless cyclic dependency in single tx? (Impossible self-conflict logic above)
			// Or just safer to break to avoid infinite loop
			if len(nextQueue) > 0 {
				// Force one to progress
				waves = append(waves, []*types.Transaction{nextQueue[0]})
				queue = nextQueue[1:]
			} else {
				break
			}
		} else {
			waves = append(waves, currentWave)
			queue = nextQueue
		}
	}

	return waves
}
