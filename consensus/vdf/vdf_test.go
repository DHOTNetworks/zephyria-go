package vdf

import (
	"bytes"
	"testing"
)

func TestVDF_ComputeAndVerify(t *testing.T) {
	v := NewVDF()
	input := []byte("hello world")
	iterations := 1000

	// 1. Compute
	output := v.Compute(input, iterations)

	// 2. Verify
	if !v.Verify(input, output, iterations) {
		t.Fatal("Verification failed for valid output")
	}

	// 3. Verify fail with wrong output
	wrongOutput := make([]byte, len(output))
	copy(wrongOutput, output)
	wrongOutput[0] ^= 0xFF
	if v.Verify(input, wrongOutput, iterations) {
		t.Fatal("Verification succeeded for invalid output")
	}

	// 4. Verify fail with wrong input
	if v.Verify([]byte("wrong input"), output, iterations) {
		t.Fatal("Verification succeeded for invalid input")
	}
}

func TestVDF_Checkpoints(t *testing.T) {
	v := NewVDF()
	input := []byte("checkpoints")
	iterations := 100
	interval := 10

	checkpoints := v.ComputeWithCheckpoints(input, iterations, interval)

	if len(checkpoints) != 10 {
		t.Fatalf("Expected 10 checkpoints, got %d", len(checkpoints))
	}

	// Verify the final checkpoint matches Compute
	final := v.Compute(input, iterations)
	if !bytes.Equal(checkpoints[len(checkpoints)-1], final) {
		t.Fatal("Last checkpoint does not match final computation")
	}

	// Verify steps
	// First step: input -> checkpoints[0]
	if !v.VerifyStep(input, checkpoints[0], interval) {
		t.Fatal("Failed to verify first step")
	}

	// Sub steps
	for i := 0; i < len(checkpoints)-1; i++ {
		if !v.VerifyStep(checkpoints[i], checkpoints[i+1], interval) {
			t.Fatalf("Failed to verify step %d", i)
		}
	}
}
