use blst::min_sig::SecretKey;
use criterion::{criterion_group, criterion_main, BatchSize, Criterion};
use rand::{thread_rng, RngCore};
use std::sync::Arc;
use zephyria_consensus::ZeliusEngine;
use zephyria_core::blockchain::Blockchain;
use zephyria_state::ZephyriaDB;
use zephyria_types::{Address, Block, Hash, Validator, U256};

fn benchmark_block_import(c: &mut Criterion) {
    // 1. Setup Data for Bench (Pre-mine blocks)
    let (blocks, engine, validators, sk_bytes, my_addr) = setup_chain_data(100);

    let mut group = c.benchmark_group("blockchain");
    group.sample_size(10); // DB ops are slow, reduce sample size

    group.bench_function("insert_100_blocks", |b| {
        b.iter_batched(
            || {
                // Setup FRESH DB for each iteration to measure write cost fairly
                let dir = tempfile::tempdir().unwrap();
                let db = Arc::new(ZephyriaDB::new(dir.path()).unwrap());
                // Re-use engine as it is stateless regarding DB
                let engine = engine.clone();
                let blockchain = Blockchain::new(db, engine).unwrap();
                (blockchain, blocks.clone(), dir) // Return dir to keep it alive
            },
            |(mut blockchain, blocks, _dir)| {
                for block in blocks {
                    blockchain.insert_block(block).unwrap();
                }
            },
            BatchSize::PerIteration,
        );
    });
    group.finish();
}

fn setup_chain_data(
    count: u64,
) -> (
    Vec<Block>,
    Arc<ZeliusEngine>,
    Vec<Validator>,
    [u8; 32],
    Address,
) {
    // Minimal mock setup similar to simulation test
    let mut sk_bytes = [0u8; 32];
    thread_rng().fill_bytes(&mut sk_bytes);
    let sk = SecretKey::key_gen(&sk_bytes, &[]).expect("key gen");
    let actual_sk_bytes = sk.to_bytes();

    let my_addr = Address::repeat_byte(0xAA);
    let validator = Validator {
        address: my_addr,
        stake: U256::from(1000),
        bls_pub_key: sk.sk_to_pk().to_bytes().to_vec().into(),
    };

    let validators = vec![validator];
    let engine = Arc::new(ZeliusEngine::new(
        validators.clone(),
        &actual_sk_bytes,
        my_addr,
    ));

    // Create Genesis context locally to mine
    let dir = tempfile::tempdir().unwrap();
    let db = Arc::new(ZephyriaDB::new(dir.path()).unwrap());
    let blockchain = Blockchain::new(db, engine.clone()).unwrap();

    let mut current_header = blockchain.current_head().clone();
    let mut mined_blocks = Vec::new();

    for i in 1..=count {
        let mut header = current_header.clone();
        header.parent_hash = current_header.hash();
        header.number = U256::from(i);
        header.coinbase = my_addr;
        header.time = 1234567890 + i;
        header.extra_data = Default::default(); // Reset extra for seal

        let slot = i; // simple slot mapping

        engine
            .seal(&mut header, slot, Hash::ZERO)
            .expect("Failed to seal");

        let block = Block {
            header: header.clone(),
            transactions: vec![],
            uncles: vec![],
        };
        mined_blocks.push(block);
        current_header = header;
    }

    (mined_blocks, engine, validators, sk_bytes, my_addr)
}

criterion_group!(benches, benchmark_block_import);
criterion_main!(benches);
