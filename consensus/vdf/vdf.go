package vdf

import (
	"crypto/sha256"
	"fmt"
)

// VDF implements a Verifiable Delay Function using sequential SHA-256 hashing.
type VDF struct {
}

// NewVDF creates a new VDF instance.
func NewVDF() *VDF {
	return &VDF{}
}

// Compute performs sequential hashing on the input for 'iterations' count.
// Output = SHA256^iterations(Input)
func (v *VDF) Compute(input []byte, iterations int) []byte {
	currentHash := input
	// Start with input. If iterations is 0, return input (identity).
	// If iterations is 1, return SHA(input).

	// Optimization: If input is not already 32 bytes (or desired hash size),
	// the first iteration does the hashing.
	// We will treat 'input' as raw data.

	for i := 0; i < iterations; i++ {
		h := sha256.Sum256(currentHash)
		currentHash = h[:]
	}

	return currentHash
}

// Verify checks if the output matches the input after 'iterations' hashes.
func (v *VDF) Verify(input []byte, output []byte, iterations int) bool {
	computed := v.Compute(input, iterations)

	if len(computed) != len(output) {
		return false
	}
	for i := range computed {
		if computed[i] != output[i] {
			return false
		}
	}
	return true
}

// ComputeWithCheckpoints returns checkpoints every 'interval' iterations.
// results[k] = SHA256^(interval * (k+1)) (Input)
func (v *VDF) ComputeWithCheckpoints(input []byte, iterations int, interval int) [][]byte {
	if interval <= 0 {
		return nil
	}
	results := make([][]byte, 0, iterations/interval)
	currentHash := input

	for i := 1; i <= iterations; i++ {
		h := sha256.Sum256(currentHash)
		currentHash = h[:]
		if i%interval == 0 {
			res := make([]byte, len(currentHash))
			copy(res, currentHash)
			results = append(results, res)
		}
	}
	return results
}

// VerifyStep verifies that SHA256^iterations(start) == end.
func (v *VDF) VerifyStep(start []byte, end []byte, iterations int) bool {
	return v.Verify(start, end, iterations)
}

// VerifyParallel verifies a chain of checkpoints in parallel.
// input -> checkpoints[0] -> checkpoints[1] ... -> checkpoints[N]
// Returns true if all segments are valid.
func (v *VDF) VerifyParallel(input []byte, checkpoints [][]byte, interval int) bool {
	if len(checkpoints) == 0 {
		return false
	}

	resultCh := make(chan bool, len(checkpoints))

	// Segment 0: input -> checkpoints[0]
	go func() {
		resultCh <- v.VerifyStep(input, checkpoints[0], interval)
	}()

	// Segments 1..N: checkpoints[i-1] -> checkpoints[i]
	for i := 1; i < len(checkpoints); i++ {
		start := checkpoints[i-1]
		end := checkpoints[i]
		go func(s, e []byte) {
			resultCh <- v.VerifyStep(s, e, interval)
		}(start, end)
	}

	// Collect results
	success := true
	for i := 0; i < len(checkpoints); i++ {
		if !<-resultCh {
			fmt.Printf("\033[1;31m[❌] VDF Verify Failed at Segment %d\033[0m\n", i)
			// Debug:
			if i == 0 {
				fmt.Printf("Seg 0 Input: %x ... %x\n", input[:4], input[len(input)-4:])
				fmt.Printf("Seg 0 Expected: %x ... %x\n", checkpoints[0][:4], checkpoints[0][len(checkpoints[0])-4:])
			} else {
				fmt.Printf("Seg %d Input (CP%d): %x ...\n", i, i-1, checkpoints[i-1][:4])
				fmt.Printf("Seg %d Expected (CP%d): %x ...\n", i, i, checkpoints[i][:4])
			}
			success = false
		}
	}
	return success
}
