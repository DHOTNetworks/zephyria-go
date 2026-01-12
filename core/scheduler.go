package core

import (
	"zephyria/state"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

// Wave contains a set of transactions that can be executed in parallel.
type Wave struct {
	Transactions []*types.Transaction
}

// schedule groups transactions into waves using a refined dependency analysis.
// It considers:
// 1. Account-level conflicts (Nonce, Balance)
// 2. Storage-level conflicts (AccessList slots)
// 3. Aquarius Program Lookups
func (e *Executor) schedule(txs []*types.Transaction, statedb *state.StateDB) [][]*types.Transaction {
	if len(txs) == 0 {
		return nil
	}

	signer := types.LatestSigner(e.config)
	var waves [][]*types.Transaction

	// Map to track current writes/reads in the active wave
	writes := make(map[string]bool)
	reads := make(map[string]bool)

	var currentWave []*types.Transaction
	var deferred []*types.Transaction

	queue := txs
	for len(queue) > 0 {
		for _, tx := range queue {
			sender, _ := types.Sender(signer, tx)
			recipient := common.Address{}
			if tx.To() != nil {
				recipient = *tx.To()
			}

			// Identify Write/Read Sets
			txWrites := make(map[string]bool)
			txReads := make(map[string]bool)

			// 1. Account Level Dependencies
			// Sender: Nonce and Balance are ALWAYS written (gas, etc)
			txWrites[string(state.NonceKey(sender))] = true
			txWrites[string(state.BalanceKey(sender))] = true

			// 4. Automatic Data Account Resolution (Aquarius Auto-Binding)
			// Always Shard Programs to Data Accounts (Private Mode).
			// This matches Executor behavior. Access Lists for the Recipient are remapped to Data Shard.

			if tx.To() != nil {
				target := recipient // Note: recipient is defined as *tx.To() above

				// Optimization: Only check if it has code (IsProgramAccount)
				if statedb.IsProgramAccount(target) {
					// It's a contract. In Aquarius, we write to the User's Data Shard.
					dataAddr := state.DeriveDataAddress(sender, target)

					// Dependency: The Data Account is WRITTEN (Balance, Storage, etc)
					txWrites[string(state.AccountStem(dataAddr))] = true

					// Dependency: The Program is READ ONLY
					txReads[string(state.ProgramKey(target))] = true
					txReads[string(state.CodeHashKey(target))] = true
				} else {
					// EOA or Precompile (or empty)
					if tx.Value().Sign() > 0 {
						txWrites[string(state.BalanceKey(target))] = true
					}
				}
			}

			// 2. Storage Level Dependencies (AccessList)
			// Crucial: If AL targets the *Recipient*, we must lock the *Data Account* (if sharded),
			// NOT the Contract Address (which would force serialization).
			for _, entry := range tx.AccessList() {
				lockAddr := entry.Address

				// Remap logic: If entry is for Recipient contract, it refers to Data Shard
				if tx.To() != nil && entry.Address == recipient && statedb.IsProgramAccount(recipient) {
					lockAddr = state.DeriveDataAddress(sender, recipient)
				}

				if len(entry.StorageKeys) == 0 {
					txWrites[string(state.AccountStem(lockAddr))] = true
					txWrites[string(state.BalanceKey(lockAddr))] = true
					txWrites[string(state.NonceKey(lockAddr))] = true
				} else {
					for _, slot := range entry.StorageKeys {
						txWrites[string(state.StorageKey(lockAddr, slot))] = true
					}
				}
			}

			// Check Conflicts with current wave
			conflict := false
			for w := range txWrites {
				if writes[w] || reads[w] {
					conflict = true
					break
				}
			}
			if !conflict {
				for r := range txReads {
					if writes[r] {
						conflict = true
						break
					}
				}
			}

			if !conflict {
				// No conflict, add to current wave
				currentWave = append(currentWave, tx)
				for w := range txWrites {
					writes[w] = true
				}
				for r := range txReads {
					reads[r] = true
				}
			} else {
				// Deferred to next wave
				deferred = append(deferred, tx)
			}
		}

		if len(currentWave) == 0 && len(deferred) > 0 {
			// Emergency: take first deferred to prevent deadlock
			currentWave = append(currentWave, deferred[0])
			deferred = deferred[1:]
		}

		waves = append(waves, currentWave)

		// Reset for next wave
		queue = deferred
		deferred = nil
		currentWave = nil
		writes = make(map[string]bool)
		reads = make(map[string]bool)
	}

	return waves
}
