package p2p

import (
	"bytes"
	"crypto/ecdsa"
	"encoding/binary"
	"errors"
	"fmt"
	"sync"

	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/rlp"
	"github.com/klauspost/reedsolomon"
)

// Constants for Erasure Coding
const (
	DataShards   = 10
	ParityShards = 20
	TotalShards  = DataShards + ParityShards
)

// Shred represents a piece of a block.
type Shred struct {
	BlockHash common.Hash    `json:"blockHash"`
	Index     uint64         `json:"index"`
	Total     uint64         `json:"total"`
	Data      []byte         `json:"data"`
	Sender    common.Address `json:"sender"`
	Signature []byte         `json:"signature"`
}

// Hash returns the hash of the shred CONTENT (excluding signature).
func (s *Shred) Hash() common.Hash {
	// Simple composition for signing
	// We sign Hash(BlockHash || Index || Total || Data)
	// Or standard RLP of a "Content" struct.
	// Manual packing for speed:
	buf := new(bytes.Buffer)
	buf.Write(s.BlockHash.Bytes())
	binary.Write(buf, binary.BigEndian, s.Index)
	binary.Write(buf, binary.BigEndian, s.Total)
	buf.Write(s.Data)
	return crypto.Keccak256Hash(buf.Bytes())
}

// Verify checks the signature against the Sender.
func (s *Shred) Verify() error {
	if len(s.Signature) == 0 {
		return errors.New("missing signature")
	}
	hash := s.Hash()
	pubKey, err := crypto.SigToPub(hash.Bytes(), s.Signature)
	if err != nil {
		return err
	}
	addr := crypto.PubkeyToAddress(*pubKey)
	if addr != s.Sender {
		return fmt.Errorf("sender mismatch: have %s, want %s", addr.Hex(), s.Sender.Hex())
	}
	return nil
}

// Rotor handles erasure coding operations.
type Rotor struct {
	enc reedsolomon.Encoder
	mu  sync.Mutex
}

func NewRotor() (*Rotor, error) {
	enc, err := reedsolomon.New(DataShards, ParityShards)
	if err != nil {
		return nil, err
	}
	return &Rotor{enc: enc}, nil
}

// ShredBlock encodes a block into shards and SIGNS them.
func (r *Rotor) ShredBlock(b *types.Block, privKey *ecdsa.PrivateKey) ([]*Shred, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	// 1. Encode Block to RLP
	data, err := rlp.EncodeToBytes(b)
	if err != nil {
		return nil, err
	}

	// 2. Split into shards
	shards, err := r.enc.Split(data)
	if err != nil {
		return nil, err
	}

	// 3. Encode Parity
	if err := r.enc.Encode(shards); err != nil {
		return nil, err
	}

	// 4. Wrap in Shred structs
	res := make([]*Shred, len(shards))
	h := b.Hash()

	sender := common.Address{}
	if privKey != nil {
		sender = crypto.PubkeyToAddress(privKey.PublicKey)
	}

	for i, s := range shards {
		shred := &Shred{
			BlockHash: h,
			Index:     uint64(i),
			Total:     uint64(len(shards)),
			Data:      s,
			Sender:    sender,
		}

		if privKey != nil {
			hash := shred.Hash()
			sig, err := crypto.Sign(hash.Bytes(), privKey)
			if err != nil {
				return nil, err
			}
			shred.Signature = sig
		}

		res[i] = shred
	}
	return res, nil
}

// Reconstruct attempts to reconstruct the block from a map of shreds.
// shredsMap: index -> data []byte
func (r *Rotor) Reconstruct(shredsMap map[uint64][]byte, origSize int) (*types.Block, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	// Prepare data slice for RS
	// Need to fill with nil if missing
	shards := make([][]byte, TotalShards)
	count := 0
	for i := 0; i < TotalShards; i++ {
		if d, ok := shredsMap[uint64(i)]; ok {
			shards[i] = d
			count++
		}
	}

	if count < DataShards {
		return nil, errors.New("not enough shards to reconstruct")
	}

	// Verify? (Optional, checks if data is consistent)
	// ok, err := r.enc.Verify(shards)
	// if !ok || err != nil {
	// 	// Attempt Reconstruct
	// }

	// Reconstruct
	if err := r.enc.Reconstruct(shards); err != nil {
		return nil, err
	}

	// Join data shards
	// Note: Reconstruct fills shards slice. Join concatenates data shards.
	var buf bytes.Buffer
	if err := r.enc.Join(&buf, shards, len(shards[0])*DataShards); err != nil {
		return nil, err
	}

	// We have padded data. RLP decoding should handle extra bytes if strictly encoded?
	// RLP usually reads what it needs.
	// BUT join writes padded size.
	// We might have trailing zeros?
	// RLP decode:
	var b types.Block
	// Create stream
	stream := rlp.NewStream(&buf, 0)
	if err := stream.Decode(&b); err != nil {
		// Retry with trimmed?
		// If padding was zeros, and RLP format is self-describing length prefix, it should stop.
		// However, if we stripped trailing zeros?
		return nil, err
	}

	return &b, nil
}
