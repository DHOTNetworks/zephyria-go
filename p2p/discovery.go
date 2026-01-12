package p2p

import (
	"encoding/json"
	"fmt"
	"math/big"
	"sort"
	"sync"
	"time"

	"github.com/syndtr/goleveldb/leveldb"
	"github.com/syndtr/goleveldb/leveldb/util"
)

// Discovery manages peer discovery and management.
type Discovery struct {
	SelfID NodeID
	Table  map[NodeID]*NodeRecord // In-memory K-Bucket (Simplified)
	DB     *leveldb.DB            // Persistent Storage
	lock   sync.RWMutex
}

// NodeRecord extends Node with metadata for scoring.
type NodeRecord struct {
	Node       *Node
	LastSeen   time.Time
	Score      int // Higher is better
	Latency    time.Duration
	IsVerified bool // Successfully connected before
}

// NewDiscovery creates a new discovery manager backed by LevelDB.
func NewDiscovery(selfID NodeID, dataDir string) *Discovery {
	dbPath := dataDir + "/discovery.ldb"
	db, err := leveldb.OpenFile(dbPath, nil)
	if err != nil {
		fmt.Printf("WARNING: Failed to open Discovery DB at %s: %v. Persistence disabled.\n", dbPath, err)
		// Fallback? nil db
	}

	return &Discovery{
		SelfID: selfID,
		Table:  make(map[NodeID]*NodeRecord),
		DB:     db,
	}
}

// LoadPeers loads peers from LevelDB.
func (d *Discovery) LoadPeers() error {
	if d.DB == nil {
		return nil
	}
	d.lock.Lock()
	defer d.lock.Unlock()

	// Iterate all keys with prefix "peer:"
	iter := d.DB.NewIterator(util.BytesPrefix([]byte("peer:")), nil)
	defer iter.Release()

	count := 0
	for iter.Next() {
		var rec NodeRecord
		if err := json.Unmarshal(iter.Value(), &rec); err == nil {
			// Skip self
			if rec.Node.ID == d.SelfID {
				continue
			}
			d.Table[rec.Node.ID] = &rec
			count++
		}
	}
	fmt.Printf("[Discovery] Loaded %d peers from DB\n", count)
	return nil
}

// SavePeers persists known peers to disk.
// With LevelDB, we save immediately on update (Write-Through).
// This method ensures everything is flushed or for bulk saves.
// Currently AddPeer handles saving.
func (d *Discovery) SavePeers() error {
	// No-op or Close?
	if d.DB != nil {
		return d.DB.Close()
	}
	return nil
}

// AddPeer adds a peer to the table and persists it.
func (d *Discovery) AddPeer(n *Node) {
	d.lock.Lock()
	defer d.lock.Unlock()

	if n.ID == d.SelfID {
		return
	}

	var rec *NodeRecord
	if r, exists := d.Table[n.ID]; exists {
		// Update IP/Port if changed
		if !r.Node.IP.Equal(n.IP) || r.Node.Port != n.Port {
			r.Node = n
		}
		r.LastSeen = time.Now()
		rec = r
	} else {
		rec = &NodeRecord{
			Node:     n,
			LastSeen: time.Now(),
			Score:    0,
		}
		d.Table[n.ID] = rec
		// fmt.Printf("[Discovery] New Peer Added: %s\n", n.String())
	}

	// Persist
	if d.DB != nil {
		// Key: peer:<hex_id>
		key := append([]byte("peer:"), n.ID[:]...)
		data, _ := json.Marshal(rec)
		d.DB.Put(key, data, nil)
	}
}

// GetRandomPeers returns n random peers.
func (d *Discovery) GetRandomPeers(n int) []*Node {
	d.lock.RLock()
	defer d.lock.RUnlock()

	// Naive random: Map iteration is random-ish in Go
	var result []*Node
	for _, rec := range d.Table {
		result = append(result, rec.Node)
		if len(result) >= n {
			break
		}
	}
	return result
}

// FindPeers returns peers closest to the target ID (XOR Distance).
// This is the core of Kademlia.
func (d *Discovery) FindPeers(target NodeID, limit int) []*Node {
	d.lock.RLock()
	defer d.lock.RUnlock()

	type sortablePeer struct {
		rec  *NodeRecord
		dist *big.Int
	}

	var sorted []sortablePeer
	targetInt := new(big.Int).SetBytes(target[:])

	for id, rec := range d.Table {
		// XOR Distance
		idInt := new(big.Int).SetBytes(id[:])
		dist := new(big.Int).Xor(idInt, targetInt)

		sorted = append(sorted, sortablePeer{rec: rec, dist: dist})
	}

	// Sort by distance (ascending)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].dist.Cmp(sorted[j].dist) < 0
	})

	var result []*Node
	for i, sp := range sorted {
		if i >= limit {
			break
		}
		result = append(result, sp.rec.Node)
	}
	return result
}

// MarkVerified marks a peer as verified (successfully connected).
func (d *Discovery) MarkVerified(id NodeID) {
	d.lock.Lock()
	defer d.lock.Unlock()
	if rec, ok := d.Table[id]; ok {
		rec.IsVerified = true
		rec.Score += 10
		rec.LastSeen = time.Now()

		// Update DB
		if d.DB != nil {
			key := append([]byte("peer:"), id[:]...)
			data, _ := json.Marshal(rec)
			d.DB.Put(key, data, nil)
		}
	}
}

// MarkBad penalizes a peer.
func (d *Discovery) MarkBad(id NodeID) {
	d.lock.Lock()
	defer d.lock.Unlock()
	if rec, ok := d.Table[id]; ok {
		rec.Score -= 50
		if rec.Score < -100 {
			delete(d.Table, id) // Evict bad peer

			// Delete from DB
			if d.DB != nil {
				key := append([]byte("peer:"), id[:]...)
				d.DB.Delete(key, nil)
			}
		} else {
			// Update DB
			if d.DB != nil {
				key := append([]byte("peer:"), id[:]...)
				data, _ := json.Marshal(rec)
				d.DB.Put(key, data, nil)
			}
		}
	}
}
