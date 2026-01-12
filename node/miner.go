package node

import (
	"fmt"
	"math/big"
	"os"
	"time"

	"zephyria/core"
	"zephyria/state"
	"zephyria/types"
	ztypes "zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/syndtr/goleveldb/leveldb"
)

// OptResult holds the result of an optimistic (speculative) block execution.
type OptResult struct {
	ParentHash common.Hash
	Txs        []*ethtypes.Transaction
	Receipts   []*types.Receipt
	Root       common.Hash
	GasUsed    uint64
	OptState   *state.StateDB
}

// StartMining starts the block production loop and PoH metronome.
func (n *Node) StartMining() {
	fmt.Println("Miner Started")

	// Determine starting VDF seed and slot from tip
	head := n.bc.CurrentBlock()
	seed := head.Hash().Bytes()
	slot := head.Header.Number.Uint64()

	// If head has VDF output, use that as seed for continuity
	vdfSize := (n.engine.VDFIterations / n.engine.VDFCheckpointInterval) * 32
	if len(head.Header.ExtraData) >= vdfSize {
		seed = head.Header.ExtraData[vdfSize-32 : vdfSize]
	}

	n.engine.Metronome.Start(seed, slot)

	n.wg.Add(1)
	go func() {
		defer n.wg.Done()
		n.loop(n.txCh, n.executor)
	}()
}

func (n *Node) loop(txCh chan *ethtypes.Transaction, executor *core.Executor) {
	batch := make([]*ethtypes.Transaction, 0)

	round := 0
	for {
		select {
		case <-n.stopCh:
			return

		// Wake up signals
		case <-n.txCh:
			// Legacy internal signal (Stake/Unstake)
			// Drain logic
		loopDrain:
			for {
				select {
				case <-n.txCh:
				default:
					break loopDrain
				}
			}
			// Fallthrough to process pool

		case <-n.poolCh:
			// TxPool signal (RPC)
			// Drain
		poolDrain:
			for {
				select {
				case <-n.poolCh:
				default:
					break poolDrain
				}
			}

			// Process Pending Transactions
			batch = n.txPool.Pending()
			if len(batch) > 0 {
				fmt.Fprintf(os.Stderr, "[Miner] Picked up %d txs from pool\n", len(batch))
			}

			if len(batch) > 0 {
				// State Pre-fetching: Warm up cache for all txs in batch
				go func(txs []*ethtypes.Transaction) {
					addrs := make([]common.Address, 0, len(txs)*2)
					for _, tx := range txs {
						if tx.To() != nil {
							addrs = append(addrs, *tx.To())
						}
					}
					n.state.Prefetch(addrs)
				}(batch)

				if len(batch) > 0 {
					go n.triggerOptimisticExecution(batch)
				}
			}

		case slot := <-n.engine.Metronome.TickCh:
			// Dynamic Validator Sync
			// We need to ensure we have the latest set before checking leader
			select {
			case <-n.stopCh:
				return
			default:
			}

			n.stateLock.Lock()
			if err := n.engine.SyncValidators(n.state); err != nil {
				fmt.Printf("Validator Sync Error: %v\n", err)
			}
			n.stateLock.Unlock()

			// Check if it's our turn to propose
			parent := n.bc.CurrentBlock()
			nextBlockNum := new(big.Int).Add(parent.Header.Number, common.Big1)

			proposer := n.engine.GetLeader(slot, parent.Hash())
			myAddr := crypto.PubkeyToAddress(n.engine.PrivateKey().PublicKey)

			if proposer == myAddr {
				miningStart := time.Now()
				// We are the Proposer for this slot!
				if len(batch) > 0 {
					fmt.Fprintf(os.Stderr, "[Miner] Proposing for Slot #%d (My Turn! Batch: %d)\n", slot, len(batch))
				}
				// Re-filter batch against LATEST state before proposing
				// This removes txs that were already included by peers while we waited
				select {
				case <-n.stopCh:
					return
				default:
				}
				n.stateLock.Lock()
				signer := ethtypes.LatestSigner(n.netCfg.ChainConfig())
				validTxs := make([]*ethtypes.Transaction, 0)
				remainingTxs := make([]*ethtypes.Transaction, 0)
				pendingNonces := make(map[common.Address]uint64)

				limit := 2800
				for _, tx := range batch {
					sender, err := ethtypes.Sender(signer, tx)
					if err != nil {
						continue
					}

					nonce, ok := pendingNonces[sender]
					if !ok {
						nonce = n.state.GetNonce(sender)
					}

					if tx.Nonce() == nonce && len(validTxs) < limit {
						validTxs = append(validTxs, tx)
						pendingNonces[sender] = nonce + 1
					} else if tx.Nonce() > nonce {
						// Future tx, keep in batch
						remainingTxs = append(remainingTxs, tx)
					} else {
						// tx.Nonce() < nonce, already used by peer, DROP
					}
				}
				batch = remainingTxs
				// Keep stateLock LOCKED for ApplyBlock!

				if len(validTxs) > 0 {
					toProcess := validTxs
					start := time.Now()

					// OPTIMISTIC FAST PATH
					n.optMu.Lock()
					opt := n.optResult
					n.optResult = nil // consume it
					n.optMu.Unlock()

					var blockReceipts []*types.Receipt
					var blockRoot common.Hash
					var gasUsed uint64

					// Create a header for the current block proposal
					header := &ztypes.Header{
						ParentHash: parent.Hash(),
						Number:     nextBlockNum,
						Time:       uint64(time.Now().Unix()),
						Coinbase:   n.netCfg.Coinbase,
						GasLimit:   n.netCfg.Params.DefaultGasLimit,
						BaseFee:    core.CalcBaseFee(n.netCfg.ChainConfig(), parent.Header),
					}

					// Compute VDF
					header.ExtraData = n.engine.ComputeVDF(parent)

					if opt != nil && opt.ParentHash == parent.Hash() && n.compareTxs(opt.Txs, toProcess) {
						fmt.Printf("\033[1;33m[⚡] Optimistic Cache Hit\033[0m (Block #%d)\n", nextBlockNum)
						opt.OptState.Merge()
						blockReceipts = opt.Receipts
						// Recalculate root from base state because OptState (overlay) cannot compute new root
						blockRoot = n.state.IntermediateRoot(false)
						gasUsed = opt.GasUsed
					} else {
						receipts, root, err := n.executor.ApplyBlock(n.state, header, toProcess)
						if err != nil {
							fmt.Println("Block execution failed:", err)
							return
						}
						blockReceipts = receipts
						blockRoot = root
						gasUsed = getGasUsed(receipts)
					}

					header.VerkleRoot = blockRoot
					header.GasUsed = gasUsed
					n.lastExecTime = time.Since(start)

					// 5. Seal (Consensus)
					block := ztypes.NewBlock(header, toProcess)
					if err := n.engine.Seal(block, slot); err != nil {
						fmt.Println("Failed to seal block:", err)
						return
					}

					// PIPELINING: 6. Broadcast IMMEDIATELY after sealing
					n.p2p.BroadcastBlock(block)

					// VOTOR: Vote for own block
					if vote, err := n.engine.CreateVote(block.Hash(), block.Header.Number.Uint64()); err == nil {
						n.votePool.AddVote(vote) // Add own vote
						// Check QC immediately (Single validator case)
						if reached, _, bitmask := n.votePool.CheckQuorum(block.Hash()); reached {
							fmt.Printf("\033[1;35m[⚡] BLOCK FINALIZED\033[0m: %s | QC Reached via %x (Self)\n", block.Hash().Hex()[:10], bitmask)
						}
						n.p2p.BroadcastVote(vote)
					}
					// 7. Persistence (Synchronous for safety)
					batchDB := new(leveldb.Batch)
					if _, err := n.state.Commit(n.bc.Database(), batchDB, block.Header.Number.Uint64()); err != nil {
						fmt.Println("State Commit failed:", err)
					}
					if err := n.bc.Database().Write(batchDB, nil); err != nil {
						fmt.Println("State persistence failed:", err)
					}
					if err := n.bc.AddBlock(block, blockReceipts); err != nil {
						fmt.Println("Failed to add block:", err)
					}

					// SYNC POH METRONOME
					vdfSize := (n.engine.VDFIterations / n.engine.VDFCheckpointInterval) * 32
					if len(header.ExtraData) >= vdfSize {
						lastVDF := header.ExtraData[vdfSize-32 : vdfSize]
						n.engine.Metronome.Sync(lastVDF, header.Number.Uint64())
					}

					// Update Metrics
					DefaultMetrics.IncBlocks()
					DefaultMetrics.IncTxs(len(toProcess))

					// Log
					elapsed := time.Since(miningStart)
					fmt.Fprintf(os.Stderr, "\033[1;32m[✓] Block Mined\033[0m #%d | \033[1;36mHash:\033[0m %s | \033[1;36mTxs:\033[0m %d | \033[1;36mGas:\033[0m %d | \033[1;35mTime:\033[0m %v (Pipelined)\n",
						block.Header.Number, block.Hash().Hex()[:10], len(toProcess), header.GasUsed, elapsed)

					// Update TxPool
					n.txPool.StateUpdate(func() *state.StateDB { return n.state })
				} else {
					// Proposer but no txs? Produce empty block to keep chain moving
					n.optMu.Lock()
					n.optResult = nil // clear cache
					n.optMu.Unlock()

					header := &ztypes.Header{
						ParentHash: parent.Hash(),
						Number:     nextBlockNum,
						Time:       uint64(time.Now().Unix()),
						Coinbase:   n.netCfg.Coinbase,
						GasLimit:   n.netCfg.Params.DefaultGasLimit,
						BaseFee:    core.CalcBaseFee(n.netCfg.ChainConfig(), parent.Header),
					}
					header.ExtraData = n.engine.ComputeVDF(parent)

					receipts, root, err := n.executor.ApplyBlock(n.state, header, []*ethtypes.Transaction{})
					if err == nil {
						header.VerkleRoot = root
						header.GasUsed = getGasUsed(receipts)
						block := ztypes.NewBlock(header, []*ethtypes.Transaction{})
						n.engine.Seal(block, uint64(round))
						n.p2p.BroadcastBlock(block)

						// 7. Persistence (Synchronous)
						batchDB := new(leveldb.Batch)
						n.state.Commit(n.bc.Database(), batchDB, block.Header.Number.Uint64())
						n.bc.Database().Write(batchDB, nil)
						n.bc.AddBlock(block, receipts)

						// SYNC POH METRONOME
						vdfSize := (n.engine.VDFIterations / n.engine.VDFCheckpointInterval) * 32
						if len(header.ExtraData) >= vdfSize {
							lastVDF := header.ExtraData[vdfSize-32 : vdfSize]
							n.engine.Metronome.Sync(lastVDF, header.Number.Uint64())
						}

						// Update Metrics
						DefaultMetrics.IncBlocks()

						// Log
						elapsed := time.Since(miningStart)
						fmt.Fprintf(os.Stderr, "\033[1;32m[✓] Block Mined\033[0m #%d | \033[1;36mHash:\033[0m %s | \033[1;36mTxs:\033[0m 0 | \033[1;36mGas:\033[0m %d | \033[1;35mTime:\033[0m %v (Empty)\n",
							block.Header.Number, block.Hash().Hex()[:10], header.GasUsed, elapsed)
					}
				}
				n.stateLock.Unlock() // Balanced unlock
			} else {
				// We are NOT the proposer. Just wait.
			}
		}
	}
}

func (n *Node) triggerOptimisticExecution(txs []*ethtypes.Transaction) {
	if len(txs) == 0 {
		return
	}

	parent := n.bc.CurrentBlock()
	nextNum := new(big.Int).Add(parent.Header.Number, common.Big1)

	// Create a mock header for optimistic execution
	header := &ztypes.Header{
		ParentHash: parent.Hash(),
		Number:     nextNum,
		Time:       uint64(time.Now().Unix()),
		Coinbase:   n.netCfg.Coinbase,
		GasLimit:   n.netCfg.Params.DefaultGasLimit,
		BaseFee:    core.CalcBaseFee(n.netCfg.ChainConfig(), parent.Header),
	}

	// Re-filter batch for speculative execution
	n.stateLock.Lock()
	signer := ethtypes.LatestSigner(n.netCfg.ChainConfig())
	validTxs := make([]*ethtypes.Transaction, 0)
	pendingNonces := make(map[common.Address]uint64)
	for _, tx := range txs {
		sender, err := ethtypes.Sender(signer, tx)
		if err != nil {
			continue
		}
		nonce, ok := pendingNonces[sender]
		if !ok {
			nonce = n.state.GetNonce(sender)
		}
		if tx.Nonce() == nonce {
			validTxs = append(validTxs, tx)
			pendingNonces[sender] = nonce + 1
		}
	}
	n.stateLock.Unlock()

	if len(validTxs) == 0 {
		return
	}

	overlay := n.state.NewOverlay()
	receipts, root, err := n.executor.ApplyBlock(overlay, header, validTxs)
	if err != nil {
		return
	}

	n.optMu.Lock()
	defer n.optMu.Unlock()
	n.optResult = &OptResult{
		ParentHash: parent.Hash(),
		Txs:        validTxs,
		Receipts:   receipts,
		Root:       root,
		GasUsed:    getGasUsed(receipts),
		OptState:   overlay,
	}
}

func (n *Node) compareTxs(a, b []*ethtypes.Transaction) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Hash() != b[i].Hash() {
			return false
		}
	}
	return true
}

func getGasUsed(receipts []*ztypes.Receipt) uint64 {
	if len(receipts) == 0 {
		return 0
	}
	return receipts[len(receipts)-1].CumulativeGasUsed
}
