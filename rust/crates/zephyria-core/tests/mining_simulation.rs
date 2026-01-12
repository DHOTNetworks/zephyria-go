use blst::min_sig::SecretKey;
use rand::{thread_rng, RngCore};
use std::sync::Arc;
use zephyria_consensus::ZeliusEngine;
use zephyria_core::blockchain::Blockchain;
use zephyria_state::ZephyriaDB;
use zephyria_types::{Address, Hash, Validator, U256};

#[test]
fn test_mining_simulation() {
    // 1. Setup Temp DB
    let dir = tempfile::tempdir().unwrap();
    let db = Arc::new(ZephyriaDB::new(dir.path()).unwrap());

    // 2. Setup Validator (Self)
    let mut sk_bytes = [0u8; 32];
    thread_rng().fill_bytes(&mut sk_bytes);
    let sk = SecretKey::key_gen(&sk_bytes, &[]).expect("key gen");
    let pk_bytes = sk.sk_to_pk().to_bytes();

    let my_addr = Address::repeat_byte(0xAA);
    let validator = Validator {
        address: my_addr,
        stake: U256::from(1000),
        bls_pub_key: pk_bytes.to_vec().into(),
    };

    let validators = vec![validator];

    let actual_sk_bytes = sk.to_bytes();
    // 3. Init Engine
    let engine = Arc::new(ZeliusEngine::new(validators, &actual_sk_bytes, my_addr));

    // 4. Init Blockchain (Genesis)
    let mut blockchain =
        Blockchain::new(db.clone(), engine.clone()).expect("Failed to create blockchain");

    let genesis = blockchain.current_head().clone();
    println!("Genesis Hash: {:?}", genesis.hash());

    // 5. Mine Block 1
    // Parent = Genesis
    // Slot = 1
    let parent_hash = genesis.hash();
    let slot = 1;
    let epoch_seed = Hash::ZERO; // Initial seed

    // Create new block template
    let mut header = genesis.clone();
    header.parent_hash = parent_hash;
    header.number = U256::from(1);
    header.coinbase = my_addr; // We are the leader (only 1 validator)
    header.time = 1234567890;

    // Check leader
    let leader = engine.get_leader(slot, parent_hash);
    assert_eq!(leader, my_addr, "We should be the leader");

    // Seal (VRF + VDF + Sig)
    engine
        .seal(&mut header, slot, epoch_seed)
        .expect("Failed to seal block");

    // Construct Block
    let block = zephyria_types::Block {
        header: header.clone(),
        transactions: vec![],
        uncles: vec![],
    };

    println!("Mined Block 1: {:?}", block.hash());

    // 6. Insert into Blockchain (This triggers verify())
    blockchain
        .insert_block(block.clone())
        .expect("Failed to insert block");

    // 7. Verify Persistence
    let head = blockchain.current_head();
    assert_eq!(head.hash(), block.hash(), "Head should be updated");

    // Verify DB fetch
    let stored_block = blockchain
        .get_block_by_hash(&block.hash())
        .unwrap()
        .unwrap();
    assert_eq!(stored_block.header.number, U256::from(1));

    println!("Mining Simulation Passed!");
}
