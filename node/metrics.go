package node

import (
	"fmt"
	"net/http"
	"sync/atomic"
)

// Metrics manages internal counters for Prometheus observability.
type Metrics struct {
	BlocksProduced uint64
	TxsProcessed   uint64
	PeersCount     int64
	SyncHeight     uint64
}

var (
	DefaultMetrics = &Metrics{}
)

// IncBlocks increments the block production counter.
func (m *Metrics) IncBlocks() {
	atomic.AddUint64(&m.BlocksProduced, 1)
}

// IncTxs increments the transaction processing counter.
func (m *Metrics) IncTxs(n int) {
	atomic.AddUint64(&m.TxsProcessed, uint64(n))
}

// SetPeers updates the peer count.
func (m *Metrics) SetPeers(n int) {
	atomic.StoreInt64(&m.PeersCount, int64(n))
}

// SetSyncHeight updates the current sync height.
func (m *Metrics) SetSyncHeight(h uint64) {
	atomic.StoreUint64(&m.SyncHeight, h)
}

// Handler returns a Prometheus-compatible text representation of metrics.
func (m *Metrics) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")

		fmt.Fprintf(w, "# HELP zephyria_blocks_produced_total Total blocks produced by this node\n")
		fmt.Fprintf(w, "# TYPE zephyria_blocks_produced_total counter\n")
		fmt.Fprintf(w, "zephyria_blocks_produced_total %d\n", atomic.LoadUint64(&m.BlocksProduced))

		fmt.Fprintf(w, "# HELP zephyria_txs_processed_total Total transactions processed in blocks\n")
		fmt.Fprintf(w, "# TYPE zephyria_txs_processed_total counter\n")
		fmt.Fprintf(w, "zephyria_txs_processed_total %d\n", atomic.LoadUint64(&m.TxsProcessed))

		fmt.Fprintf(w, "# HELP zephyria_peers_count Current number of active P2P peers\n")
		fmt.Fprintf(w, "# TYPE zephyria_peers_count gauge\n")
		fmt.Fprintf(w, "zephyria_peers_count %d\n", atomic.LoadInt64(&m.PeersCount))

		fmt.Fprintf(w, "# HELP zephyria_sync_height Current blockchain head height\n")
		fmt.Fprintf(w, "# TYPE zephyria_sync_height gauge\n")
		fmt.Fprintf(w, "zephyria_sync_height %d\n", atomic.LoadUint64(&m.SyncHeight))
	}
}
