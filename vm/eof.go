package vm

import (
	"bytes"
	"errors"
)

var (
	ErrInvalidEOF     = errors.New("invalid EOF format")
	ErrInvalidSection = errors.New("invalid section")
)

const (
	EOFMagic0   = 0xEF
	EOFMagic1   = 0x00
	EOFVersion1 = 0x01

	SectionType = 0x01
	SectionCode = 0x02
	SectionData = 0x03
	SectionTerm = 0x00
)

type EOFContainer struct {
	Header *EOFHeader
	Code   []byte
	Data   []byte
	Types  []byte
}

type EOFHeader struct {
	CodeSizes []int
}

// ParseEOF parses and validates the EOF container format (EIP-3540).
func ParseEOF(code []byte) (*EOFContainer, error) {
	if len(code) < 3 {
		return nil, ErrInvalidEOF
	}
	if code[0] != EOFMagic0 || code[1] != EOFMagic1 {
		return nil, ErrInvalidEOF
	}
	if code[2] != EOFVersion1 {
		return nil, ErrInvalidEOF
	}

	reader := bytes.NewReader(code[3:]) // Skip Magic+Version
	header := &EOFHeader{}

	// Read Sections
	// State machine for order enforcement: Type -> Code -> Data
	lastKind := 0

	var typeSize, codeSize, dataSize uint16

	for {
		kindByte, err := reader.ReadByte()
		if err != nil {
			return nil, ErrInvalidEOF
		}
		if kindByte == SectionTerm {
			break
		}

		// Read Size
		var sizeBuf [2]byte
		if _, err := reader.Read(sizeBuf[:]); err != nil {
			return nil, ErrInvalidEOF
		}
		size := uint16(sizeBuf[0])<<8 | uint16(sizeBuf[1])

		// Validate Order
		if int(kindByte) <= lastKind && kindByte != SectionCode { // Allow multiple Code sections? EIP-3540 allows multiple code sections?
			// For simplified v1 support: Allow strict Type(1) -> Code(2) -> Data(3)
			// Actually EIP-3540 v1 allows one Type, multiple Code, one Data.
			// But Type section size depends on number of Code sections.
			// Let's implement simpler model first: 1 Type, 1 Code, 0/1 Data.
			// If strict order < check fails.
			return nil, ErrInvalidEOF
		}
		lastKind = int(kindByte)

		switch kindByte {
		case SectionType:
			typeSize = size
		case SectionCode:
			codeSize = size
			header.CodeSizes = append(header.CodeSizes, int(size))
		case SectionData:
			dataSize = size
		default:
			return nil, ErrInvalidEOF
		}
	}

	// Validate presence
	if typeSize == 0 || codeSize == 0 {
		return nil, ErrInvalidEOF
	}

	// Read Types
	typesSection := make([]byte, typeSize)
	if _, err := reader.Read(typesSection); err != nil {
		return nil, ErrInvalidEOF
	}

	// Read Code
	codeSection := make([]byte, codeSize)
	if _, err := reader.Read(codeSection); err != nil {
		return nil, ErrInvalidEOF
	}

	// Read Data
	var dataSection []byte
	if dataSize > 0 {
		dataSection = make([]byte, dataSize)
		if _, err := reader.Read(dataSection); err != nil {
			return nil, ErrInvalidEOF
		}
	}

	if reader.Len() > 0 {
		return nil, ErrInvalidEOF
	}

	return &EOFContainer{
		Header: header,
		Code:   codeSection,
		Data:   dataSection,
		Types:  typesSection,
	}, nil
}

func ValidateEOF(c *EOFContainer) error {
	// Stub for deeper validation
	return nil
}
