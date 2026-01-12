use anyhow::{anyhow, Result};
use std::sync::Arc;
use zephyria_consensus::ZeliusEngine;
use zephyria_state::{Database, ZephyriaDB};
use zephyria_types::{Block, Hash, Header};

pub struct Blockchain {
    db: Arc<ZephyriaDB>,
    engine: Arc<ZeliusEngine>,
    // In-memory head
    head: Header,
}

impl Blockchain {
    pub fn new(db: Arc<ZephyriaDB>, engine: Arc<ZeliusEngine>) -> Result<Self> {
        // Load head from DB
        let head_key = b"HEAD_HASH";
        let head_hash = db.get(head_key)?;

        let head = if let Some(hash_bytes) = head_hash {
            // Fetch Header
            let block_bytes = db
                .get(&hash_bytes)?
                .ok_or(anyhow!("Head block data missing for hash {:?}", hash_bytes))?;

            let block: Block = serde_json::from_slice(&block_bytes)
                .map_err(|e| anyhow!("Failed to deserialize head block: {}", e))?;
            block.header
        } else {
            // Genesis
            Header {
                parent_hash: Hash::default(),
                uncle_hash: Hash::default(),
                coinbase: zephyria_types::Address::default(),
                state_root: Hash::default(),
                tx_hash: Hash::default(),
                receipt_hash: Hash::default(),
                bloom: zephyria_types::Bloom::default(),
                difficulty: zephyria_types::U256::default(),
                number: zephyria_types::U256::default(),
                gas_limit: 0,
                gas_used: 0,
                time: 0,
                extra_data: zephyria_types::Bytes::default(),
                mix_digest: Hash::default(),
                nonce: 0,
                base_fee: None,
            }
        };

        Ok(Self { db, engine, head })
    }

    pub fn insert_block(&mut self, block: Block) -> Result<()> {
        // 1. Consensus Verification
        self.engine
            .verify(&block.header, block.header.parent_hash)
            .map_err(|e| anyhow!("Consensus verification failed: {}", e))?;

        // 2. Store block in DB
        let hash = block.hash();
        let key = hash.as_slice();

        // Serialize block (using serde_json for robustness ensuring data is saved)
        // Ideally RLP, but serde is safe for now to close the "mock" gap.
        let bytes =
            serde_json::to_vec(&block).map_err(|e| anyhow!("Failed to serialize block: {}", e))?;

        self.db.put(key, &bytes)?;

        // Index Number -> Hash
        // Key: "Num" + big_endian_bytes(number)
        let mut num_key = b"Num".to_vec();
        num_key.extend_from_slice(&block.header.number.to_be_bytes::<32>());
        self.db.put(&num_key, hash.as_slice())?;

        // Update Head
        if block.header.number > self.head.number {
            self.head = block.header.clone();

            // Handle Epoch logic
            self.process_epoch_boundary(&self.head)?;

            // Persist Head Hash separately to allow recovery on restart
            let head_key = b"HEAD_HASH";
            self.db.put(head_key, hash.as_slice())?;
        }

        Ok(())
    }

    fn process_epoch_boundary(&self, header: &Header) -> Result<()> {
        let epoch_len = zephyria_types::U256::from(100);

        if header.number % epoch_len == zephyria_types::U256::ZERO {
            // Extract Seed
            // Last VDF Checkpoint or simple offset.
            // In Zelius Engine, VDF size was roughly 320 bytes (10 checkpoints).
            // Go code used offset 128:160.
            // We'll trust the Engine layout. For now, take first 32 bytes if available.
            if header.extra_data.len() >= 32 {
                let seed = &header.extra_data[..32];

                // Addresses
                // In Go: e.netCfg.Params.RandomnessAddr
                // For Rust PoC: Use zero address or fixed placeholder
                let randomness_addr = zephyria_types::Address::repeat_byte(0x55);

                // Keys
                let zero_key = Hash::ZERO;
                let epoch = header.number / epoch_len;
                let mut epoch_bytes = [0u8; 32];
                epoch_bytes[32 - epoch.to_be_bytes::<32>().len()..]
                    .copy_from_slice(&epoch.to_be_bytes::<32>());
                let epoch_key = Hash::from(epoch_bytes);

                // Derive State Keys: Keccak(Addr || Key)
                let mut k1 = randomness_addr.to_vec();
                k1.extend_from_slice(zero_key.as_slice());
                let state_key1 = zephyria_types::keccak256(&k1);

                let mut k2 = randomness_addr.to_vec();
                k2.extend_from_slice(epoch_key.as_slice());
                let state_key2 = zephyria_types::keccak256(&k2);

                // Write to DB
                self.db.put(state_key1.as_slice(), seed)?;
                self.db.put(state_key2.as_slice(), seed)?;

                println!("Epoch Boundary Processed: Epoch {}", epoch);
            }
        }
        Ok(())
    }

    pub fn current_head(&self) -> &Header {
        &self.head
    }

    pub fn get_block_by_hash(&self, hash: &Hash) -> Result<Option<Block>> {
        let bytes_opt = self.db.get(hash.as_slice())?;
        if let Some(bytes) = bytes_opt {
            let block: Block = serde_json::from_slice(&bytes)?;
            Ok(Some(block))
        } else {
            Ok(None)
        }
    }

    pub fn get_block_by_number(&self, number: zephyria_types::U256) -> Result<Option<Block>> {
        let mut num_key = b"Num".to_vec();
        num_key.extend_from_slice(&number.to_be_bytes::<32>());

        let hash_opt = self.db.get(&num_key)?;
        if let Some(hash_bytes) = hash_opt {
            let hash = Hash::from_slice(&hash_bytes);
            self.get_block_by_hash(&hash)
        } else {
            Ok(None)
        }
    }
}
