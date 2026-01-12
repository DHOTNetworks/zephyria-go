use anyhow::{Result, Context};
use libmdbx::{Environment, NoWriteMap, WriteFlags, Geometry};
pub mod trie;
pub mod precompile;

pub use trie::VerkleState;
use std::path::Path;
use std::sync::Arc;

pub trait Database: Send + Sync {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>>;
    fn put(&self, key: &[u8], value: &[u8]) -> Result<()>;
    fn delete(&self, key: &[u8]) -> Result<()>;
    fn batch_put(&self, pairs: &[(&[u8], &[u8])]) -> Result<()>;
}

pub struct ZephyriaDB {
    env: Arc<Environment<NoWriteMap>>,
}

impl ZephyriaDB {
    pub fn new(path: &Path) -> Result<Self> {
        let env = Environment::new()
            .set_geometry(Geometry {
                size: Some(0..(10 * 1024 * 1024 * 1024)), // 10GB growth
                ..Default::default()
            })
            .open(path)
            .map_err(|e| anyhow::anyhow!("Failed to open MDBX environment: {}", e))?;
            
        Ok(Self {
            env: Arc::new(env),
        })
    }
}

impl Database for ZephyriaDB {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>> {
        let tx = self.env.begin_ro_txn()
             .map_err(|e| anyhow::anyhow!("Failed begin ro txn: {}", e))?;
        // Open default DB. 
        // In libmdbx-rs, open_db(None) usually opens the main DB.
        let db = tx.open_db(None)
             .map_err(|e| anyhow::anyhow!("Failed open db: {}", e))?;
             
        let val = tx.get(&db, key)
             .map_err(|e| anyhow::anyhow!("Failed get: {}", e))?;
             
        // val is Cow<[u8]>
        Ok(val.map(|v: std::borrow::Cow<[u8]>| v.to_vec()))
    }

    fn put(&self, key: &[u8], value: &[u8]) -> Result<()> {
        let tx = self.env.begin_rw_txn()
             .map_err(|e| anyhow::anyhow!("Failed begin rw txn: {}", e))?;
        let db = tx.open_db(None)
             .map_err(|e| anyhow::anyhow!("Failed open db: {}", e))?;
        tx.put(&db, key, value, WriteFlags::UPSERT)
             .map_err(|e| anyhow::anyhow!("Failed put: {}", e))?;
        tx.commit()
             .map_err(|e| anyhow::anyhow!("Failed commit: {}", e))?;
        Ok(())
    }

    fn delete(&self, key: &[u8]) -> Result<()> {
        let tx = self.env.begin_rw_txn()
             .map_err(|e| anyhow::anyhow!("Failed begin rw txn: {}", e))?;
        let db = tx.open_db(None)
             .map_err(|e| anyhow::anyhow!("Failed open db: {}", e))?;
        tx.del(&db, key, None)
             .map_err(|e| anyhow::anyhow!("Failed del: {}", e))?;
        tx.commit()
             .map_err(|e| anyhow::anyhow!("Failed commit: {}", e))?;
        Ok(())
    }

    fn batch_put(&self, pairs: &[(&[u8], &[u8])]) -> Result<()> {
        let tx = self.env.begin_rw_txn()
             .map_err(|e| anyhow::anyhow!("Failed begin rw txn: {}", e))?;
        let db = tx.open_db(None)
             .map_err(|e| anyhow::anyhow!("Failed open db: {}", e))?;
        for (k, v) in pairs {
            tx.put(&db, k, v, WriteFlags::UPSERT)
             .map_err(|e| anyhow::anyhow!("Failed put in batch: {}", e))?;
        }
        tx.commit()
             .map_err(|e| anyhow::anyhow!("Failed commit batch: {}", e))?;
        Ok(())
    }
}
