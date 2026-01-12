package vm

import (
	"testing"
)

func TestParseEOF(t *testing.T) {
	tests := []struct {
		name    string
		code    []byte
		wantErr bool
	}{
		{
			name: "Valid EOF",
			// EF 00 01 | 01 00 01 | 02 00 01 | 00 | 00 | 00
			code:    []byte{0xEF, 0x00, 0x01, 0x01, 0x00, 0x01, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00},
			wantErr: false,
		},
		{
			name:    "Invalid Magic",
			code:    []byte{0xEF, 0x01, 0x01},
			wantErr: true,
		},
		{
			name:    "Invalid Version",
			code:    []byte{0xEF, 0x00, 0x02},
			wantErr: true,
		},
		{
			name:    "Short Code",
			code:    []byte{0xEF, 0x00},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := ParseEOF(tt.code)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseEOF() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}
