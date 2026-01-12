package vm

import (
	"errors"
	"fmt"

	"github.com/ethereum/go-ethereum/params"
)

// ValidateStack performs EIP-5450 stack validation.
func ValidateStack(c *EOFContainer) error {
	// For each code section
	// Assume single code section c.Code
	code := c.Code
	if len(code) == 0 {
		return nil
	}

	// Instruction Table for stack info
	table := newCancunInstructionSet()

	// Analysis state
	// PC -> Stack Height
	stackHeights := make(map[int]int)

	// Worklist: list of PCs to visit
	type workItem struct {
		pc     int
		height int
	}
	worklist := []workItem{{0, 0}}

	for len(worklist) > 0 {
		item := worklist[len(worklist)-1]
		worklist = worklist[:len(worklist)-1]
		pc := item.pc
		height := item.height

		// Check if visited
		if existingH, ok := stackHeights[pc]; ok {
			if existingH != height {
				return fmt.Errorf("stack height mismatch at %d: %d vs %d", pc, existingH, height)
			}
			continue
		}
		stackHeights[pc] = height

		// Fetch Opcode
		if pc >= len(code) {
			return errors.New("pc out of bounds")
		}
		op := OpCode(code[pc])

		// Get instruction definition
		if int(op) >= len(table) {
			return fmt.Errorf("undefined opcode 0x%x", int(op))
		}
		instr := table[op]
		if instr.execute == nil {
			return fmt.Errorf("undefined opcode 0x%x", int(op))
		}

		// Check Stack Underflow
		req := int(instr.minStack)
		if height < req {
			return fmt.Errorf("stack underflow at %d (op %v): have %d, want %d", pc, op, height, req)
		}

		// Calculate new height
		// instr.maxStack = StackLimit + minStack - push
		// => push = StackLimit + minStack - maxStack
		push := int(params.StackLimit) + int(instr.minStack) - int(instr.maxStack)
		newHeight := height - req + push
		if newHeight > 1024 {
			return fmt.Errorf("stack overflow at %d", pc)
		}

		// Determine Successors

		// Check if Terminating (STOP, RETURN, REVERT, INVALID, SELFDESTRUCT)
		isTerm := (op == STOP || op == RETURN || op == REVERT || op == INVALID || op == SELFDESTRUCT || op == RETURNCONTRACT)
		if isTerm {
			continue
		}

		if op == JUMP || op == JUMPI {
			return errors.New("dynamic jumps (JUMP/JUMPI) not allowed in EOF")
		}

		// Determine length
		length := 1
		if op >= PUSH1 && op <= PUSH32 {
			length = 1 + int(op-PUSH1+1)
		} else if op == TXCREATE || op == EOFCREATE {
			// These might have immediates?
			// EOFCREATE is 0xec.
			// Implement length logic if needed.
		}

		nextPC := pc + length
		if nextPC > len(code) {
			return errors.New("truncated instruction")
		}

		worklist = append(worklist, workItem{nextPC, newHeight})
	}

	return nil
}
