use anyhow::{Context, Result};
use verkle_trie::config::Config;
use zephyria_types::Hash;

use crate::Database;
use crate::ZephyriaDB;
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use ipa_multipoint::committer::DefaultCommitter;
use serde::{Deserialize, Serialize};
use serde_json;
use std::sync::Arc;
use verkle_trie::database::{
    BranchChild, BranchMeta, ReadOnlyHigherDb, StemMeta, WriteOnlyHigherDb,
};
use verkle_trie::Element;
use verkle_trie::Trie;
use verkle_trie::TrieTrait;

// Native Verkle Storage Implementation backed by ZephyriaDB (MDBX)
#[derive(Clone)]
pub struct VerkleStorage {
    db: Arc<ZephyriaDB>,
}

impl VerkleStorage {
    pub fn new(db: Arc<ZephyriaDB>) -> Self {
        Self { db }
    }

    fn update_list(&self, prefix: &[u8], key_main: &[u8], idx: u8) {
        let mut list_key = prefix.to_vec();
        list_key.extend_from_slice(key_main);

        let bytes_opt = self.db.get(&list_key).ok().flatten();
        let indices: Vec<u8> = if let Some(bytes) = bytes_opt {
            serde_json::from_slice(&bytes).unwrap_or_default()
        } else {
            Vec::new()
        };

        let mut new_indices = indices;
        if !new_indices.contains(&idx) {
            new_indices.push(idx);
            if let Ok(bytes) = serde_json::to_vec(&new_indices) {
                let _ = self.db.put(&list_key, &bytes);
            }
        }
    }
}

// Helpers for serialization
fn serialize_ark<T: CanonicalSerialize>(item: &T) -> Vec<u8> {
    let mut bytes = Vec::new();
    item.serialize_compressed(&mut bytes).unwrap_or_default();
    bytes
}

fn deserialize_ark<T: CanonicalDeserialize>(bytes: &[u8]) -> Option<T> {
    if bytes.is_empty() {
        return None;
    }
    T::deserialize_compressed(bytes).ok()
}

// --- storage structs ---

#[derive(Serialize, Deserialize)]
struct StoredStemMeta {
    c_1: Vec<u8>,
    hash_c1: Vec<u8>,
    c_2: Vec<u8>,
    hash_c2: Vec<u8>,
    stem_commitment: Vec<u8>,
    hash_stem_commitment: Vec<u8>,
}

#[derive(Serialize, Deserialize)]
struct StoredBranchMeta {
    commitment: Vec<u8>,
    hash_commitment: Vec<u8>,
}

#[derive(Serialize, Deserialize)]
enum StoredBranchChild {
    Stem([u8; 31]),
    Branch(StoredBranchMeta),
}

// --- Traits ---

impl ReadOnlyHigherDb for VerkleStorage {
    fn get_stem_meta(&self, stem: [u8; 31]) -> Option<StemMeta> {
        let mut key = b"SM".to_vec();
        key.extend_from_slice(&stem);
        let bytes: Vec<u8> = self.db.get(&key).ok().flatten()?;
        let stored: StoredStemMeta = serde_json::from_slice(&bytes).ok()?;

        Some(StemMeta {
            c_1: Element::from_bytes(&stored.c_1)?,
            hash_c1: deserialize_ark(&stored.hash_c1)?,
            c_2: Element::from_bytes(&stored.c_2)?,
            hash_c2: deserialize_ark(&stored.hash_c2)?,
            stem_commitment: Element::from_bytes(&stored.stem_commitment)?,
            hash_stem_commitment: deserialize_ark(&stored.hash_stem_commitment)?,
        })
    }

    fn get_branch_meta(&self, branch: &[u8]) -> Option<BranchMeta> {
        let mut key = b"BM".to_vec();
        key.extend_from_slice(branch);
        let bytes: Vec<u8> = self.db.get(&key).ok().flatten()?;
        let stored: StoredBranchMeta = serde_json::from_slice(&bytes).ok()?;

        Some(BranchMeta {
            commitment: Element::from_bytes(&stored.commitment)?,
            hash_commitment: deserialize_ark(&stored.hash_commitment)?,
        })
    }

    fn get_branch_children(&self, branch: &[u8]) -> Vec<(u8, BranchChild)> {
        let mut list_key = b"BC_LIST".to_vec();
        list_key.extend_from_slice(branch);

        let mut children = Vec::new();
        if let Ok(Some(bytes)) = self.db.get(&list_key) {
            if let Ok(indices) = serde_json::from_slice::<Vec<u8>>(&bytes) {
                for idx in indices {
                    if let Some(child) = self.get_branch_child(branch, idx) {
                        children.push((idx, child));
                    }
                }
            }
        }
        children
    }

    fn get_branch_child(&self, branch: &[u8], index: u8) -> Option<BranchChild> {
        let mut key = b"BC".to_vec();
        key.extend_from_slice(branch);
        key.push(index);
        let bytes: Vec<u8> = self.db.get(&key).ok().flatten()?;
        let stored: StoredBranchChild = serde_json::from_slice(&bytes).ok()?;

        match stored {
            StoredBranchChild::Stem(s) => Some(BranchChild::Stem(s)),
            StoredBranchChild::Branch(b) => Some(BranchChild::Branch(BranchMeta {
                commitment: Element::from_bytes(&b.commitment)?,
                hash_commitment: deserialize_ark(&b.hash_commitment)?,
            })),
        }
    }

    fn get_stem_children(&self, stem: [u8; 31]) -> Vec<(u8, [u8; 32])> {
        let mut list_key = b"SC_LIST".to_vec();
        list_key.extend_from_slice(&stem);

        let mut children = Vec::new();
        if let Ok(Some(bytes)) = self.db.get(&list_key) {
            if let Ok(indices) = serde_json::from_slice::<Vec<u8>>(&bytes) {
                for idx in indices {
                    let mut key = b"SC".to_vec();
                    key.extend_from_slice(&stem);
                    key.push(idx);
                    if let Ok(Some(val_bytes)) = self.db.get(&key) {
                        if val_bytes.len() == 32 {
                            let mut val = [0u8; 32];
                            val.copy_from_slice(&val_bytes);
                            children.push((idx, val));
                        }
                    }
                }
            }
        }
        children
    }

    fn get_leaf(&self, key: [u8; 32]) -> Option<[u8; 32]> {
        let mut db_key = b"L".to_vec();
        db_key.extend_from_slice(&key);
        let bytes: Vec<u8> = self.db.get(&db_key).ok().flatten()?;
        if bytes.len() == 32 {
            let mut val = [0u8; 32];
            val.copy_from_slice(&bytes);
            Some(val)
        } else {
            None
        }
    }
}

impl WriteOnlyHigherDb for VerkleStorage {
    fn insert_leaf(&mut self, key: [u8; 32], value: [u8; 32], _db_idx: u8) -> Option<Vec<u8>> {
        let mut db_key = b"L".to_vec();
        db_key.extend_from_slice(&key);
        let _ = self.db.put(&db_key, &value);
        None
    }

    fn insert_stem(&mut self, stem: [u8; 31], meta: StemMeta, _db_idx: u8) -> Option<StemMeta> {
        let stored = StoredStemMeta {
            c_1: meta.c_1.to_bytes().to_vec(),
            hash_c1: serialize_ark(&meta.hash_c1),
            c_2: meta.c_2.to_bytes().to_vec(),
            hash_c2: serialize_ark(&meta.hash_c2),
            stem_commitment: meta.stem_commitment.to_bytes().to_vec(),
            hash_stem_commitment: serialize_ark(&meta.hash_stem_commitment),
        };

        let mut key = b"SM".to_vec();
        key.extend_from_slice(&stem);
        let bytes = serde_json::to_vec(&stored).ok();
        if let Some(b) = bytes {
            let _ = self.db.put(&key, &b);
        }
        None
    }

    fn add_stem_as_branch_child(
        &mut self,
        branch: Vec<u8>,
        stem: [u8; 31],
        index: u8,
    ) -> Option<BranchChild> {
        let stored = StoredBranchChild::Stem(stem);

        let mut key = b"BC".to_vec();
        key.extend_from_slice(&branch);
        key.push(index);
        let bytes = serde_json::to_vec(&stored).ok();
        if let Some(b) = bytes {
            let _ = self.db.put(&key, &b);
        }

        self.update_list(b"BC_LIST", &branch, index);

        None
    }

    fn insert_branch(&mut self, branch: Vec<u8>, meta: BranchMeta, _idx: u8) -> Option<BranchMeta> {
        let stored = StoredBranchMeta {
            commitment: meta.commitment.to_bytes().to_vec(),
            hash_commitment: serialize_ark(&meta.hash_commitment),
        };

        let mut key = b"BM".to_vec();
        key.extend_from_slice(&branch);
        let bytes = serde_json::to_vec(&stored).ok();
        if let Some(b) = bytes {
            let _ = self.db.put(&key, &b);
        }
        None
    }
}

// Wrapper around the Verkle Trie
pub struct VerkleState {
    trie: Trie<VerkleStorage, DefaultCommitter>,
}

impl VerkleState {
    pub fn new(db: Arc<ZephyriaDB>) -> Self {
        let v_db = VerkleStorage::new(db);
        let config = Config::new(v_db.clone());
        let trie = Trie::new(config);

        Self { trie }
    }

    pub fn insert(&mut self, key: &[u8], value: &[u8]) -> Result<()> {
        let mut k = [0u8; 32];
        let len = std::cmp::min(key.len(), 32);
        k[..len].copy_from_slice(&key[..len]);

        let mut v = [0u8; 32];
        let len = std::cmp::min(value.len(), 32);
        v[..len].copy_from_slice(&value[..len]);

        self.trie.insert_single(k, v);
        Ok(())
    }

    pub fn root(&mut self) -> Hash {
        let root = self.trie.root_commitment();
        Hash::from_slice(&root.to_bytes())
    }

    pub fn get(&self, key: &[u8]) -> Option<Vec<u8>> {
        let mut k = [0u8; 32];
        let len = std::cmp::min(key.len(), 32);
        k[..len].copy_from_slice(&key[..len]);

        self.trie.get(k).map(|v| v.to_vec())
    }
}
