package rpc

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	ethcore "github.com/ethereum/go-ethereum/core"
	"github.com/ethereum/go-ethereum/core/types"
)

// CallArgs represents the arguments for a simulation call (eth_call, eth_estimateGas).
// It maps strict JSON types to common Go types.
type CallArgs struct {
	From                 *common.Address   `json:"from"`
	To                   *common.Address   `json:"to"`
	Gas                  *hexutil.Uint64   `json:"gas"`
	GasPrice             *hexutil.Big      `json:"gasPrice"`
	MaxFeePerGas         *hexutil.Big      `json:"maxFeePerGas"`
	MaxPriorityFeePerGas *hexutil.Big      `json:"maxPriorityFeePerGas"`
	Value                *hexutil.Big      `json:"value"`
	Data                 *hexutil.Bytes    `json:"data"`
	Input                *hexutil.Bytes    `json:"input"` // One of Data or Input is usually used
	Nonce                *hexutil.Uint64   `json:"nonce"`
	AccessList           *types.AccessList `json:"accessList"`
}

// ToMessage converts CallArgs to a core.Message for execution.
// It handles strict typing and defaults for missing fields (e.g. infinite gas for call).
func (args *CallArgs) ToMessage(globalGasCap uint64, baseFee *big.Int) (ethcore.Message, error) {
	// Set sender
	var from common.Address
	if args.From != nil {
		from = *args.From
	}

	// Set gas limit
	var gas uint64
	if args.Gas != nil {
		gas = uint64(*args.Gas)
	}
	if gas == 0 {
		gas = globalGasCap
	}

	// Set gas prices
	var (
		gasPrice  *big.Int
		gasFeeCap *big.Int
		gasTipCap *big.Int
	)

	if args.GasPrice != nil {
		gasPrice = args.GasPrice.ToInt()
		gasFeeCap = gasPrice
		gasTipCap = gasPrice
	} else if baseFee != nil {
		// EIP-1559 logic defaults
		if args.MaxFeePerGas != nil {
			gasFeeCap = args.MaxFeePerGas.ToInt()
		}
		if args.MaxPriorityFeePerGas != nil {
			gasTipCap = args.MaxPriorityFeePerGas.ToInt()
		}
		// If fee cap is set but tip is not, default tip to fee cap?
		// Or if neither set, we might need a default or just use 0.
		// For simulation, we often want to pass if possible.
		if gasFeeCap == nil {
			gasFeeCap = new(big.Int).Add(baseFee, big.NewInt(1000000000)) // Base + 1 Gwei
		}
		if gasTipCap == nil {
			gasTipCap = new(big.Int).SetInt64(1000000000) // 1 Gwei
		}
		gasPrice = gasFeeCap // Effective gas price is dynamic but we set cap here for simulated msg
	} else {
		gasPrice = new(big.Int)
	}

	var value *big.Int
	if args.Value != nil {
		value = args.Value.ToInt()
	} else {
		value = new(big.Int)
	}

	var data []byte
	if args.Data != nil {
		data = []byte(*args.Data)
	} else if args.Input != nil {
		data = []byte(*args.Input)
	}

	var accessList types.AccessList
	if args.AccessList != nil {
		accessList = *args.AccessList
	}

	// Nonce
	var nonce uint64
	if args.Nonce != nil {
		nonce = uint64(*args.Nonce)
	}

	// Return Message using ethcore.Message struct which is widely used in our codebase aliases
	msg := ethcore.Message{
		To:         args.To,
		From:       from,
		Nonce:      nonce,
		Value:      value,
		GasLimit:   gas,
		GasPrice:   gasPrice,
		GasFeeCap:  gasFeeCap,
		GasTipCap:  gasTipCap,
		Data:       data,
		AccessList: accessList,
	}
	return msg, nil
}
