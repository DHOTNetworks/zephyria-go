package node

import (
	"crypto/ecdsa"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"zephyria/consensus"
	"zephyria/core"
	"zephyria/p2p"
	zrpc "zephyria/rpc"
	"zephyria/state"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rpc"
	"github.com/syndtr/goleveldb/leveldb"
	ldbutil "github.com/syndtr/goleveldb/leveldb/util"
)

type Node struct {
	config   *Config
	db       *leveldb.DB
	bc       *core.Blockchain
	state    *state.StateDB
	engine   *consensus.ZeliusEngine
	p2p      *p2p.Server
	txPool   *core.TxPool
	votePool *consensus.VotePool

	// Components
	txCh     chan *ethtypes.Transaction
	poolCh   chan struct{} // Signal from TxPool
	executor *core.Executor

	// Running
	stopCh       chan struct{}
	blockTimeout time.Duration
	lastExecTime time.Duration
	stateLock    sync.Mutex // For pipelining coordination
	netCfg       *core.NetworkConfig
	wg           sync.WaitGroup // For graceful shutdown

	// Keystore
	keystore   map[common.Address]*ecdsa.PrivateKey
	keystoreMu sync.RWMutex

	// RPC & WS
	httpListener net.Listener
	wsListener   net.Listener
	ipcListener  net.Listener

	// Optimistic Execution
	optMu     sync.Mutex
	optResult *OptResult
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
	if genesis == nil {
		// core.NewBlockchain should have handled it.
	} else {
		if genesis.Hash() != netCfg.GenesisHash {
			return fmt.Errorf("CRITICAL: Genesis Hash Mismatch! Expected %s, got %s. Are you on the right network?", netCfg.GenesisHash.Hex(), genesis.Hash().Hex())
		}
		fmt.Printf("\033[1;32m[🛡] Genesis Verified:\033[0m %s\n", genesis.Hash().Hex()[:10])
	}

	// 3. Consensus Engine
	valKey := n.config.ValidatorKey
	if valKey == nil {
		fmt.Println("****************************************************************")
		fmt.Println("* CRITICAL SECURITY WARNING: RUNNING WITH HARDCODED DEV KEYS   *")
		fmt.Println("* DO NOT USE THIS BUILD FOR REAL VALUE. FOR TESTING ONLY.      *")
		fmt.Println("****************************************************************")
		valKey, _ = crypto.HexToECDSA(core.DefaultDevKey)
	}

	// Validators from network config
	n.engine = consensus.NewZelius(n.netCfg.Validators, valKey, &n.netCfg.Params)

	// Add default validator key to keystore
	n.AddKey(valKey)

	// Vote Pool
	n.votePool = consensus.NewVotePool(n.engine)

	// 4. TxPool
	n.txPool = core.NewTxPool(n.netCfg)
	n.txPool.SetStateProvider(func() *state.StateDB {
		return n.state
	})
	// TxPool Notification
	n.poolCh = make(chan struct{}, 1)
	n.txPool.Subscribe(n.poolCh)

	// 5. P2P Server
	p2pConfig := p2p.ServerConfig{
		ListenAddr: fmt.Sprintf(":%d", n.config.P2PPort),
		Bootnodes:  n.config.Bootnodes,
		PrivateKey: valKey,           // Pass validator key for Zelius Shield Identity
		DataDir:    n.config.DataDir, // Pass DataDir for discovery.ldb
	}
	n.p2p = p2p.NewServer(p2pConfig, n.bc, n.txPool)

	// Register Handler for P2P Blocks (Import)
	chainConfig := netCfg.ChainConfig()
	executor := core.NewExecutor(chainConfig, netCfg, n.bc)
	n.executor = executor

	// Use extracted handlers (handler.go)
	n.p2p.RegisterBlockHandler(n.HandleP2PBlock)
	n.p2p.RegisterVoteHandler(n.HandleP2PVote)
	n.p2p.RegisterSlashingHandler(n.HandleP2PSlashing)

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
		root, _ := n.state.Commit(n.db, batch, 0)
		n.db.Write(batch, nil)
		fmt.Printf("Genesis State Root: %s\n", root.Hex())
	} else {
		fmt.Printf("Loaded Chain Head: #%d | State Root: %s\n", currentHeight, stateRoot.Hex()[:10])
	}

	// 6. Executor (already inited above for handlers)

	// 7. Loop & RPC
	txCh := make(chan *ethtypes.Transaction, 2000)

	rpcServer := rpc.NewServer()

	// Register eth_ services
	fullEthAPI := zrpc.NewPublicEthAPI(n.bc, n.state, n.txPool, n.executor)
	if err := rpcServer.RegisterName("eth", fullEthAPI); err != nil {
		return err
	}

	// Register net_ services
	if err := rpcServer.RegisterName("net", zrpc.NewPublicNetAPI(n.bc, n.p2p)); err != nil {
		return err
	}

	// Register web3_ services
	if err := rpcServer.RegisterName("web3", zrpc.NewPublicWeb3API()); err != nil {
		return err
	}

	// Register txpool_ services
	if err := rpcServer.RegisterName("txpool", fullEthAPI); err != nil {
		return err
	}

	// Register Zelius API
	zeliusAPI := zrpc.NewZephyriaAPI(n)
	rpcServer.RegisterName("zelius", zeliusAPI)

	// 5. Start HTTP RPC
	if n.config.HTTPEnabled {
		addr := fmt.Sprintf("%s:%d", n.config.HTTPHost, n.config.HTTPPort)
		httpListener, err := net.Listen("tcp", addr)
		if err != nil {
			return fmt.Errorf("failed to listen on HTTP %s: %v", addr, err)
		}
		n.httpListener = httpListener

		go func() {
			fmt.Printf("RPC Server listening on %s\n", addr)

			// SECURITY: Load or Generate JWT Secret
			jwtSecretPath := n.config.DataDir + "/jwt.hex"
			jwtSecret, err := n.loadOrGenerateJWT(jwtSecretPath)
			if err != nil {
				fmt.Printf("WARNING: Failed to load JWT secret: %v. RPC Auth disabled (UNSAFE).\n", err)
			} else {
				fmt.Printf("🔒 RPC Authentication Enabled. JWT Secret: %s\n", jwtSecretPath)
			}

			// RATE LIMITING: 100 req/sec per IP
			rateLimiter := NewRateLimiter(100, time.Second)

			// CORS & Auth Handler Wrapper
			corsHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				// Metrics endpoint (no auth required)
				if r.URL.Path == "/metrics" {
					DefaultMetrics.Handler()(w, r)
					return
				}

				w.Header().Set("Access-Control-Allow-Origin", "*")
				w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS, PUT, DELETE")
				w.Header().Set("Access-Control-Allow-Headers", "*")

				if r.Method == "OPTIONS" {
					return
				}

				// AUTHENTICATION CHECK
				if jwtSecret != nil {
					auth := r.Header.Get("Authorization")
					if strings.HasPrefix(auth, "Bearer ") {
						tokenString := strings.TrimPrefix(auth, "Bearer ")
						valid := n.validateJWT(tokenString, jwtSecret)
						if !valid {
							http.Error(w, "Unauthorized", http.StatusUnauthorized)
							return
						}
					}
				}

				rpcServer.ServeHTTP(w, r)
			})

			// Apply Rate Limiting Middleware
			finalHandler := rateLimiter.Middleware(corsHandler)

			if err := http.Serve(httpListener, finalHandler); err != nil && err != http.ErrServerClosed {
				fmt.Printf("❌ HTTP Server Failed: %v\n", err)
			}
		}()
	}

	// 6. Start WebSocket RPC (if enabled)
	if n.config.WSEnabled {
		addr := fmt.Sprintf("%s:%d", n.config.WSHost, n.config.WSPort)
		wsListener, err := net.Listen("tcp", addr)
		if err != nil {
			fmt.Printf("WARNING: Failed to listen on WS %s: %v\n", addr, err)
		} else {
			n.wsListener = wsListener

			allowedOrigins := []string{"*"}
			wsHandler := rpcServer.WebsocketHandler(allowedOrigins)

			go func() {
				fmt.Printf("WebSocket Server listening on %s\n", addr)
				if err := http.Serve(wsListener, wsHandler); err != nil {
					// log
				}
			}()
		}
	}

	// 7. Start IPC RPC
	if n.config.IPCPath != "" {
		if err := os.Remove(n.config.IPCPath); err != nil && !os.IsNotExist(err) {
			fmt.Printf("WARNING: Failed to remove old IPC file: %v\n", err)
		}

		ipcListener, err := net.Listen("unix", n.config.IPCPath)
		if err != nil {
			fmt.Printf("WARNING: Failed to start IPC server: %v\n", err)
		} else {
			n.ipcListener = ipcListener
			fmt.Printf("IPC endpoint opened at %s\n", n.config.IPCPath)

			go func() {
				for {
					conn, err := ipcListener.Accept()
					if err != nil {
						return
					}
					go rpcServer.ServeCodec(rpc.NewCodec(conn), 0)
				}
			}()
		}
	}

	n.txCh = txCh
	// Start Periodic Compaction
	go n.periodicCompaction()
	// Start Metrics Updater
	go n.metricsLoop()

	return nil
}

func (n *Node) periodicCompaction() {
	ticker := time.NewTicker(24 * time.Hour)
	for {
		select {
		case <-ticker.C:
			fmt.Println("[DB] Starting periodic compaction...")
			n.db.CompactRange(ldbutil.Range{Start: nil, Limit: nil})
			fmt.Println("[DB] Periodic compaction finished.")
		case <-n.stopCh:
			return
		}
	}
}

func (n *Node) metricsLoop() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			if n.p2p != nil {
				DefaultMetrics.SetPeers(n.p2p.PeerCount())
			}
			if n.bc != nil {
				head := n.bc.CurrentBlock()
				if head != nil {
					DefaultMetrics.SetSyncHeight(head.Header.Number.Uint64())
				}
			}
		case <-n.stopCh:
			return
		}
	}
}

// Wait blocks until an interrupt signal is received.
func (n *Node) Wait() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	<-sigCh
	n.Stop()
}

func (n *Node) Stop() {
	fmt.Println("\nStopping Zephyria Node...")

	// Signal loops to stop
	select {
	case <-n.stopCh:
		// Already closed
	default:
		close(n.stopCh)
	}

	if n.p2p != nil {
		fmt.Println("Stopping P2P...")
		n.p2p.Stop()
	}

	// Wait for miner
	fmt.Println("Waiting for miner to finish...")
	n.wg.Wait()

	if n.ipcListener != nil {
		n.ipcListener.Close()
		// Best effort removal
		os.Remove(n.config.IPCPath)
	}

	if n.state != nil {
		fmt.Println("Saving State Tree Cache...")
		if err := n.state.SaveTreeCache(); err != nil {
			fmt.Printf("Failed to save state cache: %v\n", err)
		} else {
			fmt.Println("State Tree Cache saved.")
		}
	}

	if n.db != nil {
		n.db.Close()
		fmt.Println("Database closed.")
	}
}
