use zephyria_types::{Hash, Address, Bytes, U256};
use std::collections::{HashMap, BTreeSet};
use std::sync::Arc;
use parking_lot::RwLock;

// Simple TxPool
// For real implementation, needs proper Nonce/GasPrice ordering.
pub struct TxPool {
    pool: RwLock<HashMap<Hash, Bytes>>, // Bytes is raw tx for now
}

impl TxPool {
    pub fn new() -> Self {
        Self {
            pool: RwLock::new(HashMap::new()),
        }
    }

    pub fn add(&self, tx_hash: Hash, tx_content: Bytes) {
        let mut pool = self.pool.write();
        pool.insert(tx_hash, tx_content);
    }

    pub fn pending(&self) -> Vec<Hash> {
        let pool = self.pool.read();
        pool.keys().cloned().collect()
    }
    
    pub fn count(&self) -> usize {
        self.pool.read().len()
    }
}
