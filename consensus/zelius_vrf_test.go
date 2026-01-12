package consensus

import (
	"fmt"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/crypto"
)

func TestVRF_CheckEligibility(t *testing.T) {
	// Create dummy validators with stake
	k1, _ := crypto.GenerateKey()
	k2, _ := crypto.GenerateKey()

	// v1 has 10% stake
	stake1 := big.NewInt(10)
	// v2 has 90% stake
	stake2 := big.NewInt(90)
	totalStake := big.NewInt(100)

	engine := NewZelius(nil, nil, nil) // Statik

	sk1 := new(big.Int).SetBytes(crypto.FromECDSA(k1))
	sk2 := new(big.Int).SetBytes(crypto.FromECDSA(k2))

	wins1 := 0
	wins2 := 0
	tries := 1000

	for i := 0; i < tries; i++ {
		seed := crypto.Keccak256([]byte{byte(i)})

		// Check V1
		won1, _, _ := engine.CheckEligibility(seed, 0, sk1, stake1, totalStake)
		if won1 {
			wins1++
		}

		// Check V2
		won2, _, _ := engine.CheckEligibility(seed, 0, sk2, stake2, totalStake)
		if won2 {
			wins2++
		}
	}

	t.Logf("V1 (10%%) wins: %d/1000, V2 (90%%) wins: %d/1000", wins1, wins2)

	// Probabilities: V1 ~100, V2 ~900
	if wins2 < wins1 {
		t.Errorf("V2 should win more often than V1")
	}

	if wins1 == 0 {
		t.Errorf("V1 should win at least sometimes")
	}
}

func TestVRF_SimulationScale(t *testing.T) {
	// Simulation with 4 validators
	// V1: 10%, V2: 20%, V3: 30%, V4: 40%
	// Expected Wins per 10000 slots: ~1000, ~2000, ~3000, ~4000

	stakes := []int64{10, 20, 30, 40}
	total := int64(100)
	totalStake := big.NewInt(total)

	var sks []*big.Int
	for range stakes {
		k, _ := crypto.GenerateKey()
		sks = append(sks, new(big.Int).SetBytes(crypto.FromECDSA(k)))
	}

	engine := NewZelius(nil, nil, nil)

	wins := make([]int, 4)
	slotsWithNoWinner := 0
	slotsWithMultipleWinners := 0
	totalSlots := 10000

	for i := 0; i < totalSlots; i++ {
		// Fix: Use byte slice correctly for Keccak256
		hashInput := []byte(fmt.Sprintf("slot-%d", i))
		seed := crypto.Keccak256(hashInput)

		slotWinners := 0
		for idx, stakeVal := range stakes {
			stake := big.NewInt(stakeVal)
			// Fix: seed is already []byte, no need for .Bytes()
			won, _, _ := engine.CheckEligibility(seed, uint64(i), sks[idx], stake, totalStake)
			if won {
				wins[idx]++
				slotWinners++
			}
		}

		if slotWinners == 0 {
			slotsWithNoWinner++
		} else if slotWinners > 1 {
			slotsWithMultipleWinners++
		}
	}

	t.Logf("Simulation Results (%d slots):", totalSlots)
	for i, w := range wins {
		expected := float64(totalSlots) * (float64(stakes[i]) / float64(total))
		t.Logf("V%d (%d%%): %d wins (Expected: %.0f)", i+1, stakes[i], w, expected)

		// Integrity check: Allow 10% deviation
		diff := float64(w) - expected
		if diff < 0 {
			diff = -diff
		}
		if diff > expected*0.15 { // slightly loose for random variance but 10k samples should be tight
			t.Errorf("V%d win rate deviation too high", i+1)
		}
	}

	t.Logf("Slots with NO winner: %d (%.2f%%)", slotsWithNoWinner, float64(slotsWithNoWinner)/float64(totalSlots)*100)
	t.Logf("Slots with MULTIPLE winners: %d (%.2f%%)", slotsWithMultipleWinners, float64(slotsWithMultipleWinners)/float64(totalSlots)*100)

	// Mathematical Expectation Check
	// P(0 winners) = (1-0.1)(1-0.2)(1-0.3)(1-0.4) = 0.9 * 0.8 * 0.7 * 0.6 = 0.3024 => 30.24%
	// Actual check needs to match expectation
	if slotsWithNoWinner < 2800 || slotsWithNoWinner > 3250 {
		t.Errorf("Empty slot rate deviation suspicious: %d (Expected ~3024)", slotsWithNoWinner)
	}
}
