package p2p

import (
	"fmt"
	"sort"
	"sync"
	"time"

	"zephyria/core"
	"zephyria/types"

	"github.com/ethereum/go-ethereum/common"
)

const (
	MaxInflightBatches = 5
	BatchSize          = 100
	SyncMargin         = 128 // Alpenglow: Switch to Rotor/Follow mode when within this window
)

type SyncMode int

const (
	SyncIdle    SyncMode = iota
	SyncInitial          // Pipeline (Heavy)
	SyncFollow           // Light (Gaps)
)

// Syncer manages the Synchronization State Machine.
type Syncer struct {
	server *Server
	bc     *core.Blockchain

	// State
	mode          SyncMode
	activePeer    *Peer
	syncLock      sync.Mutex
	watchdogTimer *time.Timer

	// Pipelining State (SyncInitial)
	fetchHeight   uint64 // Next height to fetch headers for
	processHeight uint64 // Next height to ingest into blockchain

	inflightBatches map[uint64]bool           // Set of batch start heights currently inflight
	bufferedBatches map[uint64][]*types.Block // Buffer for out-of-order batches

	triggerCh chan struct{} // Signal to wake up the pump loop
}

func NewSyncer(server *Server) *Syncer {
	return &Syncer{
		server:          server,
		bc:              server.Blockchain,
		mode:            SyncIdle,
		inflightBatches: make(map[uint64]bool),
		bufferedBatches: make(map[uint64][]*types.Block),
		triggerCh:       make(chan struct{}, 1),
	}
}

// CheckAndStart checks if we are behind and starts the appropriate sync mode.
func (s *Syncer) CheckAndStart(bestPeer *Peer) bool {
	s.syncLock.Lock()
	defer s.syncLock.Unlock()

	current := s.bc.CurrentBlock().Header.Number.Uint64()
	if bestPeer.HeadNumber <= current {
		return false
	}

	gap := bestPeer.HeadNumber - current

	// If already syncing, check if we need to escalate or just ignore.
	if s.mode != SyncIdle {
		if s.mode == SyncFollow && gap > SyncMargin*2 {
			fmt.Printf("\033[1;33m[⚠️] Sync Escalation: Gap grew to %d. Switching to Heavy Sync.\033[0m\n", gap)
			s.mode = SyncInitial
			s.fetchHeight = current + 1
			s.processHeight = current + 1
			s.inflightBatches = make(map[uint64]bool)
			s.bufferedBatches = make(map[uint64][]*types.Block)
			if s.watchdogTimer == nil {
				s.startWatchdog()
			}
			return true
		}
		return false
	}

	s.activePeer = bestPeer

	// ALPENGLOW: If we are very low height (< 100), always use InitialSync to build foundation.
	if current < 100 {
		fmt.Printf("\033[1;33m[⚠️] Low Height (%d): Forcing InitialSync for foundation.\033[0m\n", current)
		s.mode = SyncInitial
		s.fetchHeight = current + 1
		s.processHeight = current + 1
		s.inflightBatches = make(map[uint64]bool)
		s.bufferedBatches = make(map[uint64][]*types.Block)
		s.startWatchdog()
		go s.pumpLoop()
		return true
	}

	if gap <= SyncMargin {
		fmt.Printf("\033[1;32m[🟢] Catching Up: Entering Rotor/Follow Mode (Gap %d)\033[0m\n", gap)
		s.mode = SyncFollow
		go s.pumpLoop()
		return true
	}

	fmt.Printf("\033[1;36m[🚀] Zephyrus Sync:\033[0m Starting Initial Sync. Local: #%d, Target: #%d\n", current, bestPeer.HeadNumber)
	s.mode = SyncInitial
	s.fetchHeight = current + 1
	s.processHeight = current + 1
	s.inflightBatches = make(map[uint64]bool)
	s.bufferedBatches = make(map[uint64][]*types.Block)

	s.startWatchdog()
	go s.pumpLoop()
	return true
}

func (s *Syncer) startWatchdog() {
	if s.watchdogTimer != nil {
		s.watchdogTimer.Stop()
	}
	s.watchdogTimer = time.AfterFunc(60*time.Second, func() {
		s.resetSync("Watchdog Timeout", false)
	})
}

func (s *Syncer) resetSync(reason string, chain bool) {
	s.syncLock.Lock()
	defer s.syncLock.Unlock()

	if s.mode == SyncIdle {
		return
	}

	// Transition Initial -> Follow if successfully completed.
	if chain && s.mode == SyncInitial {
		fmt.Printf("\033[1;32m[🏁] Initial Sync Complete. Switching to Follow mode.\033[0m\n")
		s.mode = SyncFollow
		if s.watchdogTimer != nil {
			s.watchdogTimer.Stop()
			s.watchdogTimer = nil
		}
		s.inflightBatches = make(map[uint64]bool)
		s.bufferedBatches = make(map[uint64][]*types.Block)
		return
	}

	fmt.Printf("\033[1;33m[⚠️] Sync Stopped: %s\033[0m\n", reason)
	s.mode = SyncIdle
	s.activePeer = nil
	s.inflightBatches = make(map[uint64]bool)
	s.bufferedBatches = make(map[uint64][]*types.Block)

	if s.watchdogTimer != nil {
		s.watchdogTimer.Stop()
		s.watchdogTimer = nil
	}
}

func (s *Syncer) pumpLoop() {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	followTicker := time.NewTicker(2 * time.Second)
	defer followTicker.Stop()

	for {
		s.syncLock.Lock()
		mode := s.mode
		s.syncLock.Unlock()

		if mode == SyncIdle {
			return
		}

		if mode == SyncInitial {
			s.processBuffer()
			s.fillPipeline()
			s.checkGap()
		}

		select {
		case <-s.server.quitCh:
			return
		case <-s.triggerCh:
			// Wake up
		case <-ticker.C:
			// Regular check
		case <-followTicker.C:
			if mode == SyncFollow {
				s.runFollowCheck()
			}
		}
	}
}

func (s *Syncer) processBuffer() {
	s.syncLock.Lock()
	defer s.syncLock.Unlock()

	if s.mode != SyncInitial {
		return
	}

	for {
		batch, ok := s.bufferedBatches[s.processHeight]
		if !ok {
			return
		}

		for _, b := range batch {
			select {
			case s.server.ingressCh <- &ingressBlock{Peer: s.activePeer, Block: b}:
			case <-s.server.quitCh:
				return
			}
		}

		lastNum := batch[len(batch)-1].Header.Number.Uint64()
		delete(s.bufferedBatches, s.processHeight)
		s.processHeight = lastNum + 1

		if s.activePeer != nil && s.processHeight+SyncMargin > s.activePeer.HeadNumber {
			go s.resetSync("Sync Handover to Rotor", true)
			return
		}
	}
}

func (s *Syncer) fillPipeline() {
	s.syncLock.Lock()
	defer s.syncLock.Unlock()

	if s.mode != SyncInitial || s.activePeer == nil {
		return
	}

	peerHead := s.activePeer.HeadNumber
	for len(s.inflightBatches) < MaxInflightBatches && s.fetchHeight <= peerHead {
		if s.fetchHeight%1000 == 0 {
			fmt.Printf("\033[1;36m[🚀] Pipeline Fetching Batch #%d...\033[0m\n", s.fetchHeight)
		}

		req := &GetHeadersMsg{
			StartNumber: s.fetchHeight,
			Limit:       BatchSize,
		}
		s.activePeer.Send(req)
		s.inflightBatches[s.fetchHeight] = true
		s.fetchHeight += BatchSize
	}
}

func (s *Syncer) checkGap() {
	s.syncLock.Lock()
	defer s.syncLock.Unlock()

	if s.mode != SyncInitial || s.activePeer == nil {
		return
	}

	if s.processHeight < s.activePeer.HeadNumber {
		_, buffered := s.bufferedBatches[s.processHeight]
		inflight := false
		for k := range s.inflightBatches {
			if s.processHeight >= k && s.processHeight < k+BatchSize {
				inflight = true
				break
			}
		}

		if !buffered && !inflight && s.fetchHeight > s.processHeight {
			fmt.Printf("\033[1;33m[🔧] Pipeline Gap Detected at #%d. Rewinding fetcher.\033[0m\n", s.processHeight)
			s.fetchHeight = s.processHeight
		}
	}
}

func (s *Syncer) runFollowCheck() {
	s.syncLock.Lock()
	defer s.syncLock.Unlock()

	if s.mode != SyncFollow || s.activePeer == nil {
		return
	}

	current := s.bc.CurrentBlock().Header.Number.Uint64()
	if s.activePeer.HeadNumber > current {
		diff := s.activePeer.HeadNumber - current
		if diff > SyncMargin*2 {
			fmt.Printf("Follow Mode: Gap %d too large, escalating.\n", diff)
			s.mode = SyncInitial
			s.fetchHeight = current + 1
			s.processHeight = current + 1
			return
		}

		req := &GetHeadersMsg{StartNumber: current + 1, Limit: uint64(diff)}
		s.activePeer.Send(req)
	}
}

func (s *Syncer) OnHeadersReceived(headers []*types.Header, peer *Peer) {
	s.syncLock.Lock()
	defer s.syncLock.Unlock()

	if s.mode == SyncIdle || s.activePeer != peer {
		return
	}

	if s.watchdogTimer != nil {
		s.watchdogTimer.Reset(60 * time.Second)
	}

	if len(headers) == 0 {
		return
	}

	var hashes []common.Hash
	for _, h := range headers {
		hashes = append(hashes, h.Hash())
	}

	req := &GetBodiesMsg{BlockHashes: hashes}
	peer.Send(req)
}

func (s *Syncer) OnBodiesReceived(blocks []*types.Block) {
	s.syncLock.Lock()
	defer s.syncLock.Unlock()

	if s.mode == SyncIdle {
		return
	}

	if s.watchdogTimer != nil {
		s.watchdogTimer.Reset(60 * time.Second)
	}

	if len(blocks) == 0 {
		return
	}

	if s.mode == SyncFollow {
		current := s.bc.CurrentBlock().Header.Number.Uint64()
		for _, b := range blocks {
			if b.Header.Number.Uint64() != current+1 {
				// Ignore out-of-order Rotor blocks during follow
				continue
			}
			// Push to ingress (syncLock is held, but ingressCh is buffered)
			select {
			case s.server.ingressCh <- &ingressBlock{Peer: s.activePeer, Block: b}:
				current++
			case <-s.server.quitCh:
				return
			default:
				// If ingress full, we drop Rotor block; syncer will catch it later if needed
				return
			}
		}
		return
	}

	// SyncInitial Logic
	sort.Slice(blocks, func(i, j int) bool {
		return blocks[i].Header.Number.Uint64() < blocks[j].Header.Number.Uint64()
	})

	startNum := blocks[0].Header.Number.Uint64()
	var matchedKey uint64
	found := false
	for key := range s.inflightBatches {
		if startNum >= key && startNum < key+BatchSize {
			matchedKey = key
			found = true
			break
		}
	}

	if found {
		delete(s.inflightBatches, matchedKey)
		s.bufferedBatches[matchedKey] = blocks

		// TIP FIX: If this batch reached the peer's head, or is a short batch,
		// ensure fetchHeight is not stuck far ahead.
		lastNum := blocks[len(blocks)-1].Header.Number.Uint64()
		if lastNum+1 > s.fetchHeight {
			// This shouldn't happen usually, but if it does, it's fine.
		} else if len(blocks) < BatchSize {
			// Short batch! The peer had less than we asked for.
			// Reset fetchHeight so we don't skip the next blocks if the peer mines them.
			if s.fetchHeight > lastNum+1 {
				s.fetchHeight = lastNum + 1
			}
		}
	} else {
		// Rotor or other source
		delete(s.inflightBatches, startNum)
		s.bufferedBatches[startNum] = blocks
	}

	select {
	case s.triggerCh <- struct{}{}:
	default:
	}
}

func (s *Syncer) IsSyncing() bool {
	s.syncLock.Lock()
	defer s.syncLock.Unlock()
	return s.mode != SyncIdle
}

func (s *Syncer) RegisterPeer(p *Peer) {}

func (s *Syncer) UnregisterPeer(p *Peer) {
	s.syncLock.Lock()
	isActive := (s.activePeer == p)
	s.syncLock.Unlock()
	if isActive {
		s.resetSync("Peer Disconnected", false)
	}
}
