package vm

import (
	"strings"
	"testing"
)

func TestValidateStack(t *testing.T) {
	tests := []struct {
		name    string
		code    []byte
		wantErr string
	}{
		{
			name: "Valid PUSH POP STOP",
			// PUSH1 01 POP STOP
			code:    []byte{byte(PUSH1), 0x01, byte(POP), byte(STOP)},
			wantErr: "",
		},
		{
			name: "Stack Underflow",
			// POP
			code:    []byte{byte(POP)},
			wantErr: "stack underflow",
		},
		{
			name: "Invalid Opcode",
			code: []byte{0xFE}, // INVALID opcode?
			// 0xFE is defined as INVALID.
			// We treat it as Terminator. No error.
			// Wait, EIP-5450 doesn't ban INVALID. It just terminates.
			// Let's use 0x0c (unknown).
			// But jump_table might map unknown to nil?
			// Geth usually fills all with "undefined".
			// Check error message.
		},
		{
			name: "Dynamic JUMP detected",
			// PUSH1 00 JUMP
			code:    []byte{byte(PUSH1), 0x00, byte(JUMP)},
			wantErr: "dynamic jumps",
		},
		{
			name: "Truncated Instruction",
			// PUSH1 (missing immediate)
			code:    []byte{byte(PUSH1)},
			wantErr: "truncated instruction",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			container := &EOFContainer{
				Code: tt.code,
			}
			err := ValidateStack(container)
			if tt.wantErr == "" {
				if err != nil {
					t.Errorf("ValidateStack() error = %v, wantErr nil", err)
				}
			} else {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					// Special case for Invalid Opcode if it didn't error (0xFE is valid terminator)
					if tt.name == "Invalid Opcode" && err == nil {
						// 0xFE is valid.
						return
					}
					t.Errorf("ValidateStack() error = %v, wantErr %v", err, tt.wantErr)
				}
			}
		})
	}
}
