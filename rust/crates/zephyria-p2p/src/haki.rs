use alloy_rlp::{Decodable, Encodable};
use anyhow::{anyhow, Result};
use k256::ecdsa::signature::{Signer, Verifier};
use k256::ecdsa::{RecoveryId, Signature, SigningKey, VerifyingKey};
use reed_solomon_erasure::galois_8::ReedSolomon;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;
use zephyria_types::{keccak256, Address, Block, Hash};

const DATA_SHARDS: usize = 10;
const PARITY_SHARDS: usize = 20;
const TOTAL_SHARDS: usize = DATA_SHARDS + PARITY_SHARDS;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Shred {
    pub block_hash: Hash,
    pub index: u64,
    pub total: u64,
    pub data: Vec<u8>,
    pub sender: Address,
    pub signature: Vec<u8>,
}

impl Shred {
    // Computes hash of content: Hash(BlockHash || Index || Total || Data)
    pub fn hash(&self) -> Hash {
        let mut buf = Vec::new();
        buf.extend_from_slice(self.block_hash.as_slice());
        buf.extend_from_slice(&self.index.to_be_bytes());
        buf.extend_from_slice(&self.total.to_be_bytes());
        buf.extend_from_slice(&self.data);
        keccak256(&buf)
    }

    pub fn verify(&self) -> Result<()> {
        if self.signature.is_empty() {
            return Err(anyhow!("missing signature"));
        }

        let hash = self.hash();

        // Go's crypto.Sign produces 65-byte [R || S || V] signature
        if self.signature.len() != 65 {
            return Err(anyhow!("invalid signature length"));
        }

        let rec_id = RecoveryId::try_from(self.signature[64])
            .or_else(|_| RecoveryId::try_from(self.signature[64] - 27))?; // Handle 27/28 offset if present

        let signature = Signature::from_slice(&self.signature[..64])?;

        let recovered_key =
            VerifyingKey::recover_from_prehash(hash.as_slice(), &signature, rec_id)?;

        // Convert recovered pubkey to Address (last 20 bytes of Keccak256(pubkey_bytes[1..]))
        // k256 encoded point is 33 bytes (compressed) or 65 (uncompressed).
        // Ethereum uses uncompressed usually but keys logic might differ.
        // Let's use standard address derivation from encoded point.
        let encoded_point = recovered_key.to_encoded_point(false); // Uncompressed
        let pub_bytes = encoded_point.as_bytes();
        // Skip first byte (0x04)
        let hash = keccak256(&pub_bytes[1..]);
        let address = Address::from_slice(&hash[12..]);

        if address != self.sender {
            return Err(anyhow!(
                "sender mismatch: have {:?}, want {:?}",
                address,
                self.sender
            ));
        }

        Ok(())
    }
}

pub struct Haki {
    enc: ReedSolomon,
    mu: Mutex<()>,
}

impl Haki {
    pub fn new() -> Result<Self> {
        let enc = ReedSolomon::new(DATA_SHARDS, PARITY_SHARDS)
            .map_err(|e| anyhow!("RS Init failed: {:?}", e))?;
        Ok(Self {
            enc,
            mu: Mutex::new(()),
        })
    }

    pub fn shred_block(&self, block: &Block, priv_key: Option<&SigningKey>) -> Result<Vec<Shred>> {
        let _lock = self.mu.lock().unwrap();

        // 1. RLP Encode
        let mut data = Vec::new();
        block.encode(&mut data);

        // 2. Split
        // Note: reed-solomon-erasure expects equal sized shards. data usually needs padding?
        // Actually, this RS lib handles padding via encode? No, client must provide proper shards?
        // Checking RS lib usage: usually you pad data to be multiple of DATA_SHARDS.

        // Go implementation calls enc.Split(data). Go's klauspost/reedsolomon handles padding automatically.
        // Rust's reed-solomon-erasure requires shards to be same length.

        // Manual Padding logic:
        let shard_size = (data.len() + DATA_SHARDS - 1) / DATA_SHARDS;
        let total_size = shard_size * DATA_SHARDS;
        data.resize(total_size, 0);

        let mut shards: Vec<Vec<u8>> = data.chunks(shard_size).map(|c| c.to_vec()).collect();
        // Extend with parity shards
        for _ in 0..PARITY_SHARDS {
            shards.push(vec![0u8; shard_size]);
        }

        // 3. Encode Parity
        self.enc
            .encode(&mut shards)
            .map_err(|e| anyhow!("RS Encode failed: {:?}", e))?;

        // 4. Wrap
        let mut res = Vec::with_capacity(TOTAL_SHARDS);
        let block_hash = block.header.hash();

        // Compute sender address
        let sender = if let Some(sk) = priv_key {
            let verifying_key = sk.verifying_key();
            let encoded_point = verifying_key.to_encoded_point(false);
            let pub_bytes = encoded_point.as_bytes();
            let hash = keccak256(&pub_bytes[1..]);
            Address::from_slice(&hash[12..])
        } else {
            Address::ZERO
        };

        for (i, shard_data) in shards.into_iter().enumerate() {
            let mut shred = Shred {
                block_hash,
                index: i as u64,
                total: TOTAL_SHARDS as u64,
                data: shard_data,
                sender,
                signature: vec![],
            };

            if let Some(sk) = priv_key {
                let hash = shred.hash();
                let (signature, rec_id) = sk.sign_recoverable(hash.as_slice())?;

                let mut sig_bytes = Vec::new();
                sig_bytes.extend_from_slice(&signature.to_bytes());
                sig_bytes.push(rec_id.to_byte()); // 0 or 1. Go expects 0/1 or 27/28.
                                                  // Usually standard is +27 or not. k256 produces 0/1.
                                                  // We'll write it as is, Reader handles it.
                shred.signature = sig_bytes;
            }
            res.push(shred);
        }

        Ok(res)
    }

    pub fn reconstruct(&self, shreds_map: HashMap<u64, Vec<u8>>) -> Result<Block> {
        let _lock = self.mu.lock().unwrap();

        // 1. Prepare shards
        let mut shards: Vec<Option<Vec<u8>>> = vec![None; TOTAL_SHARDS];
        let mut count = 0;
        let mut shard_len = 0;

        for (idx, data) in shreds_map {
            if idx < TOTAL_SHARDS as u64 {
                if shard_len == 0 {
                    shard_len = data.len();
                } else if data.len() != shard_len {
                    return Err(anyhow!("shard length mismatch"));
                }
                shards[idx as usize] = Some(data);
                count += 1;
            }
        }

        if count < DATA_SHARDS {
            return Err(anyhow!("not enough shards to reconstruct"));
        }

        // 2. Reconstruct
        // reed-solomon-erasure reconstruct expects slices
        self.enc
            .reconstruct(&mut shards)
            .map_err(|e| anyhow!("RS Reconstruct failed: {:?}", e))?;

        // 3. Join
        let mut data = Vec::new();
        for i in 0..DATA_SHARDS {
            if let Some(shard) = &shards[i] {
                data.extend_from_slice(shard);
            } else {
                return Err(anyhow!("failed to recover data shard {}", i));
            }
        }

        // 4. RLP Decode
        // Data might have padding. RLP decoding stops when object is done?
        // alloy_rlp::Decodable::decode takes a slice.
        let mut slice = data.as_slice();
        // Since we padded with zeros, and RLP format is robust, it should decode fine
        // as long as trailing zeros don't confuse it (usually they don't if it's a struct).
        // BUT strict decoders might error on trailing bytes.
        // alloy_rlp::decode eats bytes.

        let block = Block::decode(&mut slice).map_err(|e| anyhow!("RLP Decode failed: {:?}", e))?;

        Ok(block)
    }
}
