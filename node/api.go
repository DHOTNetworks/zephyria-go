package node

import (
	"crypto/ecdsa"
	"fmt"
	"math/big"

	"zephyria/core"
	ztypes "zephyria/types"

	bls12381 "github.com/consensys/gnark-crypto/ecc/bls12-381"
	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

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

	// Derive BLS Key from ECDSA Private Key (Deterministic User convenience)
	// In production, user might want separate keys, but this is safe(r) than address-based.
	seed := crypto.FromECDSA(userKey)
	sk := new(big.Int).SetBytes(seed)
	var pk bls12381.G1Affine
	pk.ScalarMultiplicationBase(sk)
	blsPub := pk.Bytes() // 48 bytes

	tx := ethtypes.NewTransaction(nonce, n.netCfg.Params.StakingAddr, amount, 100000, n.netCfg.Params.DefaultBaseFee, blsPub[:])
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
	isNew, err := n.txPool.Add(tx)
	if err == nil && isNew {
		n.p2p.BroadcastTx(tx)
		n.txCh <- tx // Keep local channel for mining loop compatibility for now
	}
}

// NonceAt returns the current nonce for an address.
func (n *Node) NonceAt(addr common.Address) uint64 {
	n.stateLock.Lock()
	defer n.stateLock.Unlock()
	return n.state.GetNonce(addr)
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

// P2PInfo returns basic P2P status.
func (n *Node) P2PInfo() (string, int) {
	if n.p2p == nil {
		return "Disabled", 0
	}
	return n.p2p.Config.ListenAddr, n.p2p.PeerCount()
}

// EnodeURL returns the self node URL.
func (n *Node) EnodeURL() string {
	if n.p2p == nil {
		return ""
	}
	return n.p2p.Self().String()
}

// AddPeer connects to a new peer.
func (n *Node) AddPeer(addr string) {
	if n.p2p != nil {
		fmt.Printf("Dialing peer %s...\n", addr)
		n.p2p.Dial(addr)
	}
}

// GetUnbondingRequests returns pending unbonding requests for an address.
func (n *Node) GetUnbondingRequests(addr common.Address) ([]*ztypes.UnbondingRequest, error) {
	n.stateLock.Lock()
	defer n.stateLock.Unlock()
	return n.executor.GetValidatorRegistry().GetUnbondingRequests(n.state, addr)
}
