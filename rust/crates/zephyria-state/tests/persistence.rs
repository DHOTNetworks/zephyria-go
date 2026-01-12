use anyhow::Result;
use std::sync::Arc;
use tempfile::tempdir;
use zephyria_state::{VerkleState, ZephyriaDB};

#[test]
fn test_verkle_persistence_integration() -> Result<()> {
    let dir = tempdir()?;
    let db_path = dir.path().join("db");

    let k1 = b"key100000000000000000000000000000"; // 32 bytes approx
    let v1 = b"val100000000000000000000000000000";
    let root_hash;

    // 1. Write to DB
    {
        println!("Opening DB at {:?}", db_path);
        let db = Arc::new(ZephyriaDB::new(&db_path)?);
        let mut state = VerkleState::new(db);
        state.insert(k1, v1)?;
        root_hash = state.root();
        println!("Initial Root: {:?}", root_hash);
    }

    // 2. Re-open DB and verify persistence
    {
        println!("Re-opening DB at {:?}", db_path);
        let db = Arc::new(ZephyriaDB::new(&db_path)?);
        let mut state = VerkleState::new(db);

        // Verify Root is consistent
        let new_root = state.root();
        println!("Restored Root: {:?}", new_root);
        assert_eq!(root_hash, new_root, "Roots should match after restart");

        // Verify Key retrieval
        let val = state.get(k1);
        assert!(val.is_some(), "Value should be retrievable");

        let mut v1_32 = [0u8; 32];
        let len = std::cmp::min(v1.len(), 32);
        v1_32[..len].copy_from_slice(&v1[..len]);
        assert_eq!(val.unwrap(), v1_32.to_vec());
    }

    Ok(())
}
