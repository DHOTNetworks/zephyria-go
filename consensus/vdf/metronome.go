package vdf

import (
	"crypto/sha256"
	"fmt"
	"os"
	"runtime"
	"sync"
	"time"
)

// Metronome provides a cryptographic clock based on sequential hashing.
type Metronome struct {
	TickCh chan uint64 // Emits new Slot Number

	iterations int // Current hashes per tick
	interval   int // Checkpoint interval

	// Dynamic Governor
	targetMin time.Duration
	targetMax time.Duration

	mu          sync.RWMutex
	currentHash []byte
	currentSlot uint64
	isRunning   bool
	stopCh      chan struct{}
}

// NewMetronome creates a new VDF-based clock.
func NewMetronome(iters, interval int) *Metronome {
	return &Metronome{
		TickCh:     make(chan uint64, 10),
		iterations: iters,
		interval:   interval,
		targetMin:  300 * time.Millisecond,
		targetMax:  500 * time.Millisecond,
		stopCh:     make(chan struct{}),
	}
}

// Start launches the background hashing loop.
func (m *Metronome) Start(seed []byte, startSlot uint64) {
	m.mu.Lock()
	if m.isRunning {
		m.mu.Unlock()
		return
	}
	m.currentHash = seed
	m.currentSlot = startSlot
	m.isRunning = true
	m.mu.Unlock()

	go m.run()
}

// Stop halts the metronome.
func (m *Metronome) Stop() {
	m.mu.Lock()
	if !m.isRunning {
		m.mu.Unlock()
		return
	}
	close(m.stopCh)
	m.isRunning = false
	m.mu.Unlock()
}

// Sync resets the metronome to a specific state (e.g. after block import).
func (m *Metronome) Sync(newHash []byte, newSlot uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()

	// We only sync if the new slot is ahead or we are forced to.
	// In the blockchain context, any valid AddBlock should sync us to tip.
	m.currentHash = newHash
	m.currentSlot = newSlot

	fmt.Printf("\033[1;36m[⏲] Metronome Synced to Slot #%d | Hash: %x...\033[0m\n", newSlot, newHash[:4])
}

func (m *Metronome) run() {
	// Force the VDF loop to a single OS thread to minimize context switching jitter
	// and strictly adhere to "one CPU core" requirement.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	fmt.Fprintf(os.Stderr, "[⏲] Secured VDF Metronome Started (Fixed Iters=%d, Target=%v-%v)\n",
		m.iterations, m.targetMin, m.targetMax)

	for {
		select {
		case <-m.stopCh:
			return
		default:
			start := time.Now()

			m.mu.RLock()
			hash := m.currentHash
			iters := m.iterations // This is now a PROTOCOL CONSTANT
			m.mu.RUnlock()

			// 1. Core Cryptographic Sequential Loop (Proof of History)
			// Mandatory 800,000 hashes.
			for i := 0; i < iters; i++ {
				h := sha256.Sum256(hash)
				hash = h[:]
			}

			// 2. Measure & Governor Logic
			elapsed := time.Since(start)

			// 3. Compensation & Sleep (Wall-clock enforcement)
			// We do NOT change 'iters'. Instead, we wait if we are too fast.
			if elapsed < m.targetMin {
				sleepTime := m.targetMin - elapsed
				time.Sleep(sleepTime)
			}
			// Note: If elapsed > targetMax, the hardware is simply slower.
			// No iteration reduction allowed (Security Risk).

			// 4. Update State & Emit
			m.mu.Lock()
			m.currentHash = hash
			m.currentSlot++
			slot := m.currentSlot
			m.mu.Unlock()

			// Emit Tick
			select {
			case m.TickCh <- slot:
			default:
				// Dropping if network is overloaded
			}
		}
	}
}

// CurrentState returns the current VDF head.
func (m *Metronome) CurrentState() ([]byte, uint64) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.currentHash, m.currentSlot
}
