package vm

import "github.com/ethereum/go-ethereum/common"

const (
	// CallCreateDepth is the maximum depth of the call stack.
	CallCreateDepth = 1024

	// MaxCodeSize is the maximum size of a contract's code.
	MaxCodeSize = 24576

	// SystemAddress is the address where the system contract is stored.
	// Used for EIP-4788 (Beacon Roots) and others.
	// 0xfffffffffffffffffffffffffffffffffffffffe
)

const (
	EcrecoverGas                    = 3000
	Sha256PerWordGas                = 12
	Sha256BaseGas                   = 60
	Ripemd160PerWordGas             = 120
	Ripemd160BaseGas                = 600
	IdentityPerWordGas              = 3
	IdentityBaseGas                 = 15
	Bn256AddGasIstanbul             = 150
	Bn256ScalarMulGasIstanbul       = 6000
	Bn256PairingBaseGasIstanbul     = 45000
	Bn256PairingPerPointGasIstanbul = 34000
	Blake2FGasPerRound              = 1

	// Legacy (Unused in Cancun but might be referenced)
	Bn256AddGasByzantium             = 500
	Bn256ScalarMulGasByzantium       = 40000
	Bn256PairingBaseGasByzantium     = 100000
	Bn256PairingPerPointGasByzantium = 80000

	Bls12381G1AddGas          = 375   // Price for BLS12-381 elliptic curve G1 point addition
	Bls12381G1MulGas          = 12000 // Price for BLS12-381 elliptic curve G1 point scalar multiplication
	Bls12381G2AddGas          = 600   // Price for BLS12-381 elliptic curve G2 point addition
	Bls12381G2MulGas          = 22500 // Price for BLS12-381 elliptic curve G2 point scalar multiplication
	Bls12381PairingBaseGas    = 37700 // Base gas price for BLS12-381 elliptic curve pairing check
	Bls12381PairingPerPairGas = 32600 // Per-point pair gas price for BLS12-381 elliptic curve pairing check
	Bls12381MapG1Gas          = 5500  // Gas price for BLS12-381 mapping field element to G1 operation
	Bls12381MapG2Gas          = 23800 // Gas price for BLS12-381 mapping field element to G2 operation

	P256VerifyGas uint64 = 6900 // secp256r1 elliptic curve signature verifier gas price

	BlobTxPointEvaluationPrecompileGas = 50000 // Gas price for the point evaluation precompile.

	// Standard Gas Costs
	MemoryGas                         = 3
	QuadCoeffDiv                      = 512
	CopyGas                           = 3
	ExpGas                            = 10
	LogGas                            = 375
	LogTopicGas                       = 375
	LogDataGas                        = 8
	Keccak256WordGas                  = 6
	InitCodeWordGas                   = 2
	CallNewAccountGas                 = 25000
	CallValueTransferGas              = 9000
	SelfdestructRefundGas             = 24000
	MaxInitCodeSize                   = 49152 // 2 * 24576
	ExpByteEIP158                     = 50
	SloadGasEIP2200                   = 800
	SstoreSentryGasEIP2200            = 2300
	SstoreSetGasEIP2200               = 20000
	SstoreResetGasEIP2200             = 5000
	SstoreClearsScheduleRefundEIP2200 = 15000
	SstoreSetGas                      = 20000
	SstoreResetGas                    = 5000
	SstoreClearGas                    = 5000
	SstoreRefundGas                   = 15000
	NetSstoreNoopGas                  = 200
	NetSstoreInitGas                  = 20000
	NetSstoreCleanGas                 = 5000
	NetSstoreDirtyGas                 = 200
	NetSstoreClearRefund              = 15000
	NetSstoreResetRefund              = 4800
	NetSstoreResetClearRefund         = 19800
	SelfdestructGasEIP150             = 5000
	CreateBySelfdestructGas           = 25000
	CallStipend                       = 2300

	// EIP-1884
	SloadGasEIP1884       = 800
	BalanceGasEIP1884     = 700
	ExtcodeHashGasEIP1884 = 700

	// EIP-2929
	WarmStorageReadCostEIP2929   = 100
	ColdSloadCostEIP2929         = 2100
	ColdAccountAccessCostEIP2929 = 2600

	// Legacy / Base Gas
	ExtcodeHashGasConstantinople = 400
	CreateGas                    = 32000
	Create2Gas                   = 32000
	CallGasEIP150                = 700
	BalanceGasEIP150             = 400
	ExtcodeSizeGasEIP150         = 700
	SloadGasEIP150               = 200
	ExtcodeCopyBaseEIP150        = 700
	CallGasFrontier              = 40
	Keccak256Gas                 = 30
	BalanceGasFrontier           = 20
	ExtcodeSizeGasFrontier       = 20
	ExtcodeCopyBaseFrontier      = 20
	SloadGasFrontier             = 50
	JumpdestGas                  = 1
)

// Bls12381G1MultiExpDiscountTable is the gas discount table for BLS12-381 G1 multi exponentiation operation
var Bls12381G1MultiExpDiscountTable = [128]uint64{1000, 949, 848, 797, 764, 750, 738, 728, 719, 712, 705, 698, 692, 687, 682, 677, 673, 669, 665, 661, 658, 654, 651, 648, 645, 642, 640, 637, 635, 632, 630, 627, 625, 623, 621, 619, 617, 615, 613, 611, 609, 608, 606, 604, 603, 601, 599, 598, 596, 595, 593, 592, 591, 589, 588, 586, 585, 584, 582, 581, 580, 579, 577, 576, 575, 574, 573, 572, 570, 569, 568, 567, 566, 565, 564, 563, 562, 561, 560, 559, 558, 557, 556, 555, 554, 553, 552, 551, 550, 549, 548, 547, 547, 546, 545, 544, 543, 542, 541, 540, 540, 539, 538, 537, 536, 536, 535, 534, 533, 532, 532, 531, 530, 529, 528, 528, 527, 526, 525, 525, 524, 523, 522, 522, 521, 520, 520, 519}

// Bls12381G2MultiExpDiscountTable is the gas discount table for BLS12-381 G2 multi exponentiation operation
var Bls12381G2MultiExpDiscountTable = [128]uint64{1000, 1000, 923, 884, 855, 832, 812, 796, 782, 770, 759, 749, 740, 732, 724, 717, 711, 704, 699, 693, 688, 683, 679, 674, 670, 666, 663, 659, 655, 652, 649, 646, 643, 640, 637, 634, 632, 629, 627, 624, 622, 620, 618, 615, 613, 611, 609, 607, 606, 604, 602, 600, 598, 597, 595, 593, 592, 590, 589, 587, 586, 584, 583, 582, 580, 579, 578, 576, 575, 574, 573, 571, 570, 569, 568, 567, 566, 565, 563, 562, 561, 560, 559, 558, 557, 556, 555, 554, 553, 552, 552, 551, 550, 549, 548, 547, 546, 545, 545, 544, 543, 542, 541, 541, 540, 539, 538, 537, 537, 536, 535, 535, 534, 533, 532, 532, 531, 530, 530, 529, 528, 528, 527, 526, 526, 525, 524, 524}

var SystemAddress = common.HexToAddress("0xfffffffffffffffffffffffffffffffffffffffe")
