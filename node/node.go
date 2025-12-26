package node

import (
	"crypto/ecdsa"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"sync"
	"syscall"
	"time"

	"zephyria/consensus"
	"zephyria/core"
	"zephyria/p2p"
	zrpc "zephyria/rpc"
	"zephyria/state"
	"zephyria/types"
	ztypes "zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rpc"
	"github.com/syndtr/goleveldb/leveldb"
)

type Node struct {
	config *Config
	db     *leveldb.DB
	bc     *core.Blockchain
	state  *state.StateDB
	engine *consensus.ZeliusEngine
	p2p    *p2p.Server

	// Components
	txCh     chan *ethtypes.Transaction
	executor *core.Executor

	// Running
	stopCh       chan struct{}
	blockTimeout time.Duration
	lastExecTime time.Duration
	stateLock    sync.Mutex // For pipelining coordination
	netCfg       *core.NetworkConfig

	// Keystore
	keystore   map[common.Address]*ecdsa.PrivateKey
	keystoreMu sync.RWMutex

	// RPC & WS
	httpListener net.Listener
	wsListener   net.Listener
}

func New(cfg *Config) *Node {
	return &Node{
		config:   cfg,
		stopCh:   make(chan struct{}),
		keystore: make(map[common.Address]*ecdsa.PrivateKey),
	}
}

func (n *Node) Start() error {
	// 1. Database
	db, err := leveldb.OpenFile(n.config.DataDir, nil)
	if err != nil {
		return fmt.Errorf("failed to open database: %w", err)
	}
	n.db = db

	// 2. Blockchain
	netCfg := core.GetNetworkConfig(n.config.Network)
	n.netCfg = netCfg
	n.blockTimeout = netCfg.ConsensusCfg.BlockTimeout

	n.bc = core.NewBlockchain(db, netCfg)

	// Recovery: Load State from Head
	head := n.bc.CurrentBlock()
	var stateRoot common.Hash
	if head != nil {
		stateRoot = head.Header.VerkleRoot
	}

	n.state = state.New(stateRoot, n.bc.Database()) // Pass DB

	// Verify Genesis Hash
	genesis := n.bc.GetBlockByNumber(0)
	// Basic verification...
	if genesis == nil {
		// Should ideally panic or create genesis if missing?
		// core.NewBlockchain should have handled it.
	} else {
		if genesis.Hash() != netCfg.GenesisHash {
			return fmt.Errorf("CRITICAL: Genesis Hash Mismatch! Expected %s, got %s. Are you on the right network?", netCfg.GenesisHash.Hex(), genesis.Hash().Hex())
		}
		fmt.Printf("\033[1;32m[🛡] Genesis Verified:\033[0m %s\n", genesis.Hash().Hex()[:10])
	}

	// 5. Consensus Engine
	valKey := n.config.ValidatorKey
	if valKey == nil {
		fmt.Println("****************************************************************")
		fmt.Println("* CRITICAL SECURITY WARNING: RUNNING WITH HARDCODED DEV KEYS   *")
		fmt.Println("* DO NOT USE THIS BUILD FOR REAL VALUE. FOR TESTING ONLY.      *")
		fmt.Println("****************************************************************")
		valKey, _ = crypto.HexToECDSA(core.DefaultDevKey)
	}

	// Validators from network config
	n.engine = consensus.NewZelius(n.netCfg.Validators, valKey)

	// Add default validator key to keystore
	n.AddKey(valKey)

	// 4. P2P Server
	p2pConfig := p2p.ServerConfig{
		ListenAddr: fmt.Sprintf(":%d", n.config.P2PPort),
		Bootnodes:  n.config.Bootnodes,
		PrivateKey: valKey, // Pass validator key for Zelius Shield Identity
	}
	n.p2p = p2p.NewServer(p2pConfig, n.bc)

	// Register Handler for P2P Blocks (Import)
	// Note: We need Executor logic to run on imported blocks.
	// For PoC, the p2p handler just adds to blockchain.
	// PROBLEM: Adding to blockchain doesn't update StateDB.
	// We need to run ApplyBlock.
	// We'll define a simple Import logic here.
	// ... (This logic remains, but we might want to update it later to fix sync persistence) ...

	chainConfig := netCfg.ChainConfig()
	executor := core.NewExecutor(chainConfig, netCfg)

	n.p2p.RegisterBlockHandler(func(p *p2p.Peer, b *ztypes.Block) {
		n.stateLock.Lock()
		defer n.stateLock.Unlock()

		// Import Block Logic
		// 1. Validate Signature (Security)
		if err := n.engine.Verify(b); err != nil {
			fmt.Printf("P2P Import Rejected (Signature): %v\n", err)
			return
		}

		// 2. Execute
		receipts, root, err := executor.ApplyBlock(n.state, b.Header, b.Transactions)
		if err != nil {
			fmt.Printf("P2P Import Failed (Exec): %v\n", err)
			return
		}
		b.Header.VerkleRoot = root

		// 3. Commit State
		batch := new(leveldb.Batch)
		n.state.Commit(n.bc.Database(), batch)
		n.db.Write(batch, nil)

		// 4. Add to Chain
		if err := n.bc.AddBlock(b, receipts); err != nil {
			fmt.Printf("P2P Import Failed (Add): %v\n", err)
		} else {
			fmt.Printf("Imported P2P Block #%d\n", b.Header.Number)
		}
	})

	if err := n.p2p.Start(); err != nil {
		fmt.Printf("P2P Start Failed: %v\n", err)
	}

	// 5. Genesis/Allocation (Only if fresh chain)
	currentHeight := uint64(0)
	if head != nil {
		currentHeight = head.Header.Number.Uint64()
	}

	if currentHeight == 0 {
		fmt.Println("Initializing Genesis State...")
		for addr, balance := range n.netCfg.Alloc {
			n.state.SetBalance(addr, balance, 0)
		}
		batch := new(leveldb.Batch)
		root, _ := n.state.Commit(n.db, batch)
		n.db.Write(batch, nil)
		fmt.Printf("Genesis State Root: %s\n", root.Hex())
	} else {
		fmt.Printf("Loaded Chain Head: #%d | State Root: %s\n", currentHeight, stateRoot.Hex()[:10])
	}

	// 6. Executor
	n.executor = core.NewExecutor(netCfg.ChainConfig(), netCfg)

	// 7. Loop & RPC
	txCh := make(chan *ethtypes.Transaction, 2000)

	rpcServer := rpc.NewServer()
	ethAPI := zrpc.NewPublicEthAPI(n.bc, n.state, txCh)
	rpcServer.RegisterName("eth", ethAPI)

	// Register Zelius API
	zeliusAPI := zrpc.NewZephyriaAPI(n)
	rpcServer.RegisterName("zelius", zeliusAPI)

	// 5. Start HTTP RPC
	httpListener, err := net.Listen("tcp", fmt.Sprintf(":%d", n.config.HTTPPort))
	if err != nil {
		return fmt.Errorf("failed to listen on HTTP port: %v", err)
	}
	n.httpListener = httpListener

	go func() {
		fmt.Printf("RPC Server listening on :%d\n", n.config.HTTPPort)
		// Handler logic
		// We use go-ethereum's internal HTTP logic usually via ServeHandler or similar?
		// rpc.Server implements http.Handler.
		if err := http.Serve(httpListener, rpcServer); err != nil {
			// check close error
		}
	}()

	// 6. Start WebSocket RPC (if port configured)
	if n.config.WSPort > 0 {
		wsListener, err := net.Listen("tcp", fmt.Sprintf(":%d", n.config.WSPort))
		if err != nil {
			fmt.Printf("WARNING: Failed to listen on WS port %d: %v\n", n.config.WSPort, err)
		} else {
			n.wsListener = wsListener

			// WS Handler
			// Geth rpc server has WebsocketHandler method
			allowedOrigins := []string{"*"}
			wsHandler := rpcServer.WebsocketHandler(allowedOrigins)

			go func() {
				fmt.Printf("WebSocket Server listening on :%d\n", n.config.WSPort)
				if err := http.Serve(wsListener, wsHandler); err != nil {
					// log
				}
			}()
		}
	}

	n.txCh = txCh
	n.executor = executor

	return nil
}

// StartMining starts the block production loop.
func (n *Node) StartMining() {
	fmt.Println("Miner Started")
	go n.loop(n.txCh, n.executor)
}

// Wait blocks until an interrupt signal is received.
func (n *Node) Wait() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	<-sigCh
	n.Stop()
}

// AddKey adds a private key to the node's keystore.
func (n *Node) AddKey(key *ecdsa.PrivateKey) {
	n.keystoreMu.Lock()
	defer n.keystoreMu.Unlock()
	addr := crypto.PubkeyToAddress(key.PublicKey)
	n.keystore[addr] = key
	fmt.Printf("[Keystore] Imported key for %s\n", addr.Hex())
}

// GetKey retrieves a private key for an address.
func (n *Node) GetKey(addr common.Address) *ecdsa.PrivateKey {
	n.keystoreMu.RLock()
	defer n.keystoreMu.RUnlock()
	return n.keystore[addr]
}

// SendStakeTx creates and sends a staking transaction.
func (n *Node) SendStakeTx(amount *big.Int, from common.Address) error {
	userKey := n.GetKey(from)
	if userKey == nil {
		return fmt.Errorf("account %s not found in keystore", from.Hex())
	}

	// Get Nonce (PoC: Read directly from state - assumption: no pending txs in pool for this user)
	nonce := n.state.GetNonce(from)

	chainConfig := n.netCfg.ChainConfig()

	tx := ethtypes.NewTransaction(nonce, n.netCfg.Params.StakingAddr, amount, 100000, n.netCfg.Params.DefaultBaseFee, nil)
	signedTx, err := ethtypes.SignTx(tx, ethtypes.LatestSigner(chainConfig), userKey)
	if err != nil {
		return fmt.Errorf("failed to sign stake tx: %v", err)
	}

	fmt.Printf("Submitting STAKE Transaction: %s\n", signedTx.Hash().Hex())
	n.txCh <- signedTx
	return nil
}

// SendUnstakeTx creates and sends an unstake transaction.
func (n *Node) SendUnstakeTx(from common.Address) error {
	userKey := n.GetKey(from)
	if userKey == nil {
		return fmt.Errorf("account %s not found in keystore", from.Hex())
	}

	nonce := n.state.GetNonce(from)
	chainConfig := n.netCfg.ChainConfig()

	tx := ethtypes.NewTransaction(nonce, n.netCfg.Params.StakingAddr, big.NewInt(0), 100000, n.netCfg.Params.DefaultBaseFee, []byte("UNSTAKE"))
	signedTx, err := ethtypes.SignTx(tx, ethtypes.LatestSigner(chainConfig), userKey)
	if err != nil {
		return fmt.Errorf("failed to sign unstake tx: %v", err)
	}

	fmt.Printf("Submitting UNSTAKE Transaction: %s\n", signedTx.Hash().Hex())
	n.txCh <- signedTx
	return nil
}

// DialPeer dials a remote peer (Exposed for Simulation).
func (n *Node) DialPeer(addr string) {
	if n.p2p != nil {
		n.p2p.Dial(addr)
	}
}

// SubmitTx submits a transaction to the node (Exposed for Simulation).
func (n *Node) SubmitTx(tx *ethtypes.Transaction) {
	n.txCh <- tx
}

// Blockchain returns the underlying blockchain instance (Exposed for Simulation).
func (n *Node) Blockchain() *core.Blockchain {
	return n.bc
}

// GetBalance returns the balance of an account from the current state.
func (n *Node) GetBalance(addr common.Address) *big.Int {
	n.stateLock.Lock()
	defer n.stateLock.Unlock()
	return n.state.GetBalance(addr).ToBig()
}

func (n *Node) loop(txCh chan *ethtypes.Transaction, executor *core.Executor) {
	ticker := time.NewTicker(n.blockTimeout)
	defer ticker.Stop()

	batch := make([]*ethtypes.Transaction, 0)
	var roundStart time.Time

	// Graceful Shutdown (Moved to Wait())
	// sigCh := make(chan os.Signal, 1)
	// signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	processBatch := func(txs []*ethtypes.Transaction) {
		if len(txs) > 0 {
			fmt.Printf("Processing batch of %d txs...\n", len(txs))
		} else {
			// Debug log for empty batches if needed, but keeping it clean for now
		}

		// Optimization: Parallel Signature Verification
		// Re-create chain config for signer
		chainConfig := n.netCfg.ChainConfig()
		signer := ethtypes.LatestSigner(chainConfig)

		var wg sync.WaitGroup
		workers := runtime.NumCPU()
		if len(txs) < workers {
			workers = len(txs)
		}

		// Valid transactions that pass signature verification
		validTxs := make([]*ethtypes.Transaction, 0, len(txs))
		var validTxMu sync.Mutex

		workCh := make(chan *ethtypes.Transaction, len(txs))

		for i := 0; i < workers; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for tx := range workCh {
					if _, err := ethtypes.Sender(signer, tx); err != nil {
						fmt.Printf(" [!] Invalid Tx Signature: %v (Hash: %s)\n", err, tx.Hash().Hex())
					} else {
						validTxMu.Lock()
						validTxs = append(validTxs, tx)
						validTxMu.Unlock()
					}
				}
			}()
		}
		for _, tx := range txs {
			workCh <- tx
		}
		close(workCh)
		wg.Wait()

		// Use only valid txs for further processing
		txs = validTxs

		// ---------------------------------------------------------
		// Advanced PoS: Intercept Staking Transactions
		// ---------------------------------------------------------
		stakingAddr := n.netCfg.Params.StakingAddr
		for _, tx := range txs {
			if tx.To() != nil && *tx.To() == stakingAddr {
				sender, _ := ethtypes.Sender(signer, tx) // Already verified

				if string(tx.Data()) == "UNSTAKE" {
					fmt.Printf(">>> UNSTAKE TX DETECTED: %s left validator set <<<\n", sender.Hex())
					n.engine.RemoveValidator(sender)
				} else if tx.Value().Sign() > 0 {
					stake := tx.Value()
					fmt.Printf(">>> STAKING TX DETECTED: %s staked %s <<<\n", sender.Hex(), stake.String())
				}
			}
		}

		// 2. Proposer Selection
		// Seed based on parent hash?
		parent := n.bc.CurrentBlock()
		// seed := crypto.Keccak256Hash(parent.Hash().Bytes())
		// For PoC: Just use randomness or simple round robin from engine?
		// The engine has SelectProposer(seed).
		// We should only mine if WE are the proposer?
		// For single node PoC, we are always proposer.
		// For Multi-node, we should check.
		// proposer := n.engine.SelectProposer(parent.Hash())
		// if proposer != n.address { return }

		// 3. Create Header ... (rest of logic)
		n.stateLock.Lock() // Ensure previous block I/O finished

		header := &ztypes.Header{
			ParentHash: parent.Hash(),
			Number:     new(big.Int).Add(parent.Header.Number, common.Big1),
			Time:       uint64(time.Now().Unix()),
			Coinbase:   n.netCfg.Coinbase,
			GasLimit:   n.netCfg.Params.DefaultGasLimit,
			BaseFee:    n.netCfg.Params.DefaultBaseFee,
			Difficulty: n.netCfg.Difficulty,
		}

		// 4. Execution
		receipts, root, err := n.executor.ApplyBlock(n.state, header, txs)
		if err != nil {
			fmt.Println("Block execution failed:", err)
			return
		}
		header.VerkleRoot = root
		header.GasUsed = getGasUsed(receipts)

		// 5. Seal (Consensus)
		block := ztypes.NewBlock(header, txs)
		if err := n.engine.Seal(block); err != nil {
			fmt.Println("Failed to seal block:", err)
			return
		}

		// PIPELINING: 6. Broadcast IMMEDIATELY after sealing
		n.p2p.BroadcastBlock(block)

		// 7. Async Persistence
		go func(blocks *ztypes.Block, txsBatch []*ethtypes.Transaction, receiptsGroup []*types.Receipt) {
			defer n.stateLock.Unlock() // Release for next block's execution

			batch := new(leveldb.Batch)
			if _, err := n.state.Commit(n.bc.Database(), batch); err != nil {
				fmt.Println("State Commit failed:", err)
			}
			if err := n.bc.Database().Write(batch, nil); err != nil {
				fmt.Println("State persistence failed:", err)
			}
			if err := n.bc.AddBlock(blocks, receiptsGroup); err != nil {
				fmt.Println("Failed to add block:", err)
			}
		}(block, txs, receipts)

		// Log
		elapsed := time.Since(roundStart)
		fmt.Printf("\033[1;32m[✓] Block Mined\033[0m #%d | \033[1;36mHash:\033[0m %s | \033[1;36mTxs:\033[0m %d | \033[1;36mGas:\033[0m %d | \033[1;36mTime:\033[0m %v (Pipelined)\n",
			block.Header.Number, block.Hash().Hex()[:10], len(txs), header.GasUsed, elapsed)
	}

	round := 0
	for {
		select {
		case <-n.stopCh:
			return
		case tx := <-n.txCh:
			batch = append(batch, tx)
			// Drain as much as possible to avoid constant select switching
			for len(batch) < 5000 {
				select {
				case next := <-n.txCh:
					batch = append(batch, next)
				default:
					goto drained
				}
			}
		drained:
			if len(batch) > 0 {
				// State Pre-fetching: Warm up cache for all txs in batch
				go func(txs []*ethtypes.Transaction) {
					addrs := make([]common.Address, 0, len(txs)*2)
					for _, tx := range txs {
						// Note: we don't have the signer here easily without re-creating,
						// but 'To' is easy. For sender, we'd need to recover.
						// For PoC, prefetching 'To' is a good start.
						if tx.To() != nil {
							addrs = append(addrs, *tx.To())
						}
					}
					n.state.Prefetch(addrs)
				}(batch)
			}

		case <-ticker.C:
			roundStart = time.Now()
			// Check if it's our turn to propose
			parent := n.bc.CurrentBlock()
			nextBlockNum := new(big.Int).Add(parent.Header.Number, common.Big1)

			// Zelius: Use GetLeader with next block number
			proposer := n.engine.GetLeader(nextBlockNum.Uint64())
			myAddr := crypto.PubkeyToAddress(n.engine.PrivateKey().PublicKey)

			if proposer == myAddr {
				if len(batch) > 0 {
					limit := 2800
					if len(batch) < limit {
						limit = len(batch)
					}
					toProcess := batch[:limit]
					batch = batch[limit:]

					start := time.Now()
					processBatch(toProcess)
					n.lastExecTime = time.Since(start)

					// Dynamic Smoothing: adjust ticker for next round
					newTimeout := n.netCfg.ConsensusCfg.BlockTimeout
					if n.lastExecTime > n.netCfg.ConsensusCfg.BlockTimeout/2 {
						// execution is heavy, slow down
						newTimeout = n.lastExecTime * 2
						if newTimeout > 5*time.Second {
							newTimeout = 5 * time.Second // cap at 5s
						}
					}
					ticker.Reset(newTimeout)

					round = 0
				} else {
					// Proposer but no txs? Produce empty block to keep chain moving if needed,
					// or just wait. Usually we produce a block.
					processBatch([]*ethtypes.Transaction{})
					round = 0
				}
			} else {
				// We are NOT the proposer.
				// fmt.Printf("\033[1;34m[ℹ] Proposer Wait:\033[0m Current proposer is %s. Waiting for block...\n", proposer.Hex()[:10])
				startWait := time.Now()
				timeout := n.blockTimeout
				blockArrived := false

			waitLoop:
				for time.Since(startWait) < timeout {
					if n.bc.CurrentBlock().Header.Number.Cmp(parent.Header.Number) > 0 {
						blockArrived = true
						break waitLoop
					}
					time.Sleep(50 * time.Millisecond)
				}

				if !blockArrived {
					fmt.Printf("\033[1;33m[!] CONSENSUS TIMEOUT:\033[0m Proposer %s failed (Round %d). Shifting...\n", proposer.Hex()[:10], round)
					n.engine.RecordNonCompliance(proposer)
					round++
				} else {
					// fmt.Printf("\033[1;34m[ℹ] Block Arrived\033[0m #%d (Round %d Reset)\n", n.bc.CurrentBlock().Header.Number, round)
					round = 0 // Block arrived, reset round
				}
			}
		}
	}
}

func getGasUsed(receipts []*ztypes.Receipt) uint64 {
	if len(receipts) == 0 {
		return 0
	}
	return receipts[len(receipts)-1].CumulativeGasUsed
}

func (n *Node) Stop() {
	fmt.Println("\nStopping Zephyria Node...")
	if n.p2p != nil {
		n.p2p.Stop()
	}
	if n.db != nil {
		n.db.Close()
		fmt.Println("Database closed.")
	}
}

// P2PInfo returns basic P2P status.
func (n *Node) P2PInfo() (string, int) {
	if n.p2p == nil {
		return "Disabled", 0
	}
	return n.p2p.Config.ListenAddr, n.p2p.PeerCount()
}

// AddPeer connects to a new peer.
func (n *Node) AddPeer(addr string) {
	if n.p2p != nil {
		fmt.Printf("Dialing peer %s...\n", addr)
		n.p2p.Dial(addr)
	}
}
