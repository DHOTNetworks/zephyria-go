package rpc

import (
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

func (api *PublicNetAPI) Listening() bool {
	return true
}

func (api *PublicNetAPI) PeerCount() hexutil.Uint {
	if api.p2p == nil {
		return 0
	}
	return hexutil.Uint(api.p2p.PeerCount())
}

func (api *PublicNetAPI) Version() string {
	return api.bc.Config().ChainID.String()
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
