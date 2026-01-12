package rpc

import (
	"fmt"
	"os"
	"zephyria/core"

	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/crypto"
)

// ---------------------------------------------------------------------
// Net API
// ---------------------------------------------------------------------

// PeerManager is an interface to get peer info.
type PeerManager interface {
	PeerCount() int
}

type PublicNetAPI struct {
	bc  *core.Blockchain
	p2p PeerManager
}

func NewPublicNetAPI(bc *core.Blockchain, p2p PeerManager) *PublicNetAPI {
	return &PublicNetAPI{bc, p2p}
}

func (api *PublicNetAPI) Listening() (bool, error) {
	fmt.Fprintf(os.Stderr, "[RPC] net_listening called\n")
	return true, nil
}

func (api *PublicNetAPI) PeerCount() (hexutil.Uint, error) {
	fmt.Fprintf(os.Stderr, "[RPC] net_peerCount called\n")
	if api.p2p == nil {
		return 0, nil
	}
	return hexutil.Uint(api.p2p.PeerCount()), nil
}

func (api *PublicNetAPI) Version() (string, error) {
	fmt.Fprintf(os.Stderr, "[RPC] net_version called\n")
	return api.bc.Config().ChainID.String(), nil
}

// ---------------------------------------------------------------------
// Web3 API
// ---------------------------------------------------------------------

type PublicWeb3API struct{}

func NewPublicWeb3API() *PublicWeb3API {
	return &PublicWeb3API{}
}

func (api *PublicWeb3API) ClientVersion() string {
	return "Zephyria/v1.0.0/go-zephyria"
}

func (api *PublicWeb3API) Sha3(input hexutil.Bytes) hexutil.Bytes {
	return crypto.Keccak256(input)
}
