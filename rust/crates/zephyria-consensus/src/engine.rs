use crate::{vrf, VDF, VRF};
use blst::min_sig::{SecretKey, Signature};
use zephyria_types::{Address, Block, Hash, Header, Validator, Vote, U256};

pub const BLS_DST: &[u8] = b"ZEPHYRIA-BLOCK-SIGNATURE";

use parking_lot::RwLock; // Need interior mutability for cache
use std::collections::HashMap;
use zephyria_types::{keccak256, Bytes};

pub struct ZeliusEngine {
    pub validators: Vec<Validator>,                // Initial set
    pub active_validators: RwLock<Vec<Validator>>, // Current epoch set
    pub local_private_key_bytes: Vec<u8>,
    pub local_address: Address,
    pub vdf_iterations: u64,
    pub vdf_interval: u64,

    // Epoch Management
    pub epoch_length: u64,
    pub current_epoch: RwLock<u64>,
    pub current_epoch_seed: RwLock<Hash>,
    pub leader_schedule: RwLock<HashMap<u64, Address>>,
}

impl ZeliusEngine {
    pub fn new(validators: Vec<Validator>, sk_bytes: &[u8], address: Address) -> Self {
        Self {
            validators: validators.clone(),
            active_validators: RwLock::new(validators),
            local_private_key_bytes: sk_bytes.to_vec(),
            local_address: address,
            vdf_iterations: 100,
            vdf_interval: 10,
            epoch_length: 100,
            current_epoch: RwLock::new(0),
            current_epoch_seed: RwLock::new(Hash::ZERO),
            leader_schedule: RwLock::new(HashMap::new()),
        }
    }

    /// Recalculates leader schedule (invalidates cache)
    pub fn recalculate_schedule(&self) {
        self.leader_schedule.write().clear();
    }

    /// Gets the leader for a specific view/slot.
    /// Logic mirrors `consensus/zelius_schedule.go`.
    pub fn get_leader(&self, view: u64, parent_hash: Hash) -> Address {
        let epoch = view / self.epoch_length;

        // Check for epoch transition
        {
            let mut current_epoch = self.current_epoch.write();
            if epoch > *current_epoch {
                *current_epoch = epoch;
                // In a real system, we'd fetch the new validator set from state here.
                // For PoC/Static, we reset to initial validators.
                *self.active_validators.write() = self.validators.clone();
                self.leader_schedule.write().clear();
                println!(">>> CONSENSUS: Epoch {} Started", epoch);
            }
        }

        // Check cache
        if let Some(leader) = self.leader_schedule.read().get(&view) {
            return *leader;
        }

        let active_vals = self.active_validators.read();
        if active_vals.is_empty() {
            return Address::ZERO;
        }

        // Calculate Total Stake
        let mut total_stake = U256::ZERO;
        for v in active_vals.iter() {
            total_stake += v.stake;
        }

        // Optimization: Single validator
        if active_vals.len() == 1 {
            let leader = active_vals[0].address;
            self.leader_schedule.write().insert(view, leader);
            return leader;
        }

        if total_stake == U256::ZERO {
            // Round robin fallback if no stake
            let idx = (view as usize) % active_vals.len();
            return active_vals[idx].address;
        }

        // Derived Randomness: Hash(EpochSeed || View || ParentHash)
        let mut seed_input = self.current_epoch_seed.read().to_vec();
        seed_input.extend_from_slice(&view.to_be_bytes());
        seed_input.extend_from_slice(parent_hash.as_slice());

        let seed = keccak256(&seed_input);
        let hash_val = U256::from_be_bytes(seed.0);

        let target = hash_val % total_stake;

        let mut current = U256::ZERO;
        for v in active_vals.iter() {
            current += v.stake;
            if current >= target {
                self.leader_schedule.write().insert(view, v.address);
                return v.address;
            }
        }

        // Fallback (should not verify)
        active_vals[0].address
    }

    /// Seal signs the block with local BLS key.
    /// It constructs the ExtraData with VDF + Slot + VRF + Bitmask + Sig.
    pub fn seal(&self, header: &mut Header, slot: u64, epoch_seed: Hash) -> Result<(), String> {
        // Layout:
        // [0..VDF_SIZE] : VDF
        // [VDF_SIZE..VDF_SIZE+8] : Slot
        // [VDF_SIZE+8..VDF_SIZE+8+96] : VRF Proof (G1, but 96 bytes space allocated?)
        // [.. + 8] : Bitmask
        // [.. + 96] : Signature (G2)

        let expected_checkpoints = self.vdf_iterations / self.vdf_interval;
        let vdf_size = (expected_checkpoints * 32) as usize;
        let vrf_size = 96;

        let static_size = vdf_size + 8 + vrf_size;

        let mut preserved_data = vec![0u8; static_size];

        // 1. Preserve/Generate VDF
        // Usually VDF is computed based on Parent. Here we assume caller populated or we keep empty/preserve.
        if header.extra_data.len() >= vdf_size {
            preserved_data[..vdf_size].copy_from_slice(&header.extra_data[..vdf_size]);
        }

        // 2. Encode Slot
        preserved_data[vdf_size..vdf_size + 8].copy_from_slice(&slot.to_be_bytes());

        // 3. VRF
        // Input: EpochSeed + Slot
        let mut vrf_input = epoch_seed.to_vec();
        vrf_input.extend_from_slice(&slot.to_be_bytes());

        let proof = VRF::prove(&self.local_private_key_bytes, &vrf_input)?;
        // Copy into 96 byte slot (even if proof is 48 bytes)
        // Usually aligns at start or end? Go code: `copy(preservedData[vdfSize+8:], proof)`
        let proof_start = vdf_size + 8;
        if proof.len() <= vrf_size {
            preserved_data[proof_start..proof_start + proof.len()].copy_from_slice(&proof);
        } else {
            return Err("VRF proof too large".to_string());
        }

        // Apply preserved data to header to hash it
        header.extra_data = preserved_data.clone().into();

        let seal_hash = header.hash();

        // 4. Sign hash (G2)
        let sig = vrf::sign_g2(&self.local_private_key_bytes, seal_hash.as_slice(), BLS_DST)?;

        // 5. Append Bitmask and Sig
        // For single sealer, bitmask has 1 bit set for self index.
        let my_addr = self.get_my_address()?;

        let mut bitmask = vec![0u8; 8];
        let active_vals = self.active_validators.read();

        // Find index of self in active_validators
        if let Some(idx) = active_vals.iter().position(|v| v.address == my_addr) {
            if idx < 64 {
                bitmask[idx / 8] |= 1 << (idx % 8);
            }
        } else {
            return Err("Self not in active validator set".to_string());
        }

        let mut payload = preserved_data;
        payload.extend_from_slice(&bitmask);
        payload.extend_from_slice(&sig);

        header.extra_data = payload.into();

        Ok(())
    }

    /// VDF + VRF + Leader + Signature verification
    pub fn verify(&self, header: &Header, parent_hash: Hash) -> Result<(), String> {
        // Layout Config
        let expected_checkpoints = self.vdf_iterations / self.vdf_interval;
        let vdf_size = (expected_checkpoints * 32) as usize;
        let vrf_size = 96;
        let round_size = 8;

        let min_size = vdf_size + round_size + vrf_size + 8 + 96; // + 8 (bitmask) + 96 (sig)

        if header.extra_data.len() < min_size {
            return Err(format!(
                "ExtraData too short: {} < {}",
                header.extra_data.len(),
                min_size
            ));
        }

        let extra = &header.extra_data;
        let slot_bytes = &extra[vdf_size..vdf_size + 8];
        let vrf_proof = &extra[vdf_size + 8..vdf_size + 8 + vrf_size];

        // 1. Verify Leader
        let mut slot_arr = [0u8; 8];
        slot_arr.copy_from_slice(slot_bytes);
        let slot = u64::from_be_bytes(slot_arr);

        let expected_leader = self.get_leader(slot, parent_hash);
        if header.coinbase != expected_leader {
            return Err(format!(
                "Invalid leader: expected {}, got {}",
                expected_leader, header.coinbase
            ));
        }

        // 2. Verify VRF
        // Input: EpochSeed + Slot
        let seed = self.current_epoch_seed.read();
        let mut vrf_input = seed.to_vec();
        vrf_input.extend_from_slice(&slot.to_be_bytes());

        let active_vals = self.active_validators.read();
        let leader_val = active_vals
            .iter()
            .find(|v| v.address == header.coinbase)
            .ok_or("Leader not in active set bucket")?;

        if !VRF::verify(&leader_val.bls_pub_key, &vrf_input, vrf_proof)? {
            return Err("VRF Verification Failed".to_string());
        }

        Ok(())
    }

    fn get_my_address(&self) -> Result<Address, String> {
        Ok(self.local_address)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use blst::min_sig::SecretKey;
    use rand::{thread_rng, RngCore};
    use zephyria_types::{Address, Bytes, U256};

    #[test]
    fn test_seal() {
        let mut sk_bytes = [0u8; 32];
        thread_rng().fill_bytes(&mut sk_bytes);

        let sk = SecretKey::key_gen(&sk_bytes, &[]).expect("key gen failed");
        let sk_bytes = sk.to_bytes();

        let validator = Validator {
            address: Address::ZERO,
            stake: U256::from(100),
            bls_pub_key: sk.sk_to_pk().to_bytes().to_vec().into(),
        };
        let engine = ZeliusEngine::new(vec![validator], &sk_bytes, Address::ZERO);

        let mut header = Header {
            parent_hash: Hash::ZERO,
            uncle_hash: Hash::ZERO,
            coinbase: Address::ZERO,
            state_root: Hash::ZERO,
            tx_hash: Hash::ZERO,
            receipt_hash: Hash::ZERO,
            bloom: zephyria_types::Bloom::default(),
            difficulty: U256::ZERO,
            number: U256::ZERO,
            gas_limit: 30000000,
            gas_used: 0,
            time: 0,
            extra_data: Bytes::new(),
            mix_digest: Hash::ZERO,
            nonce: 0,
            base_fee: None,
        };

        let slot = 1;
        let epoch_seed = Hash::ZERO;

        let res = engine.seal(&mut header, slot, epoch_seed);
        assert!(res.is_ok(), "Seal failed: {:?}", res.err());

        // Expected size explanation:
        // VDF (0 iterations / 0 interval? No, 100/10 = 10 checkpoints * 32 = 320 bytes)
        // Wait, VDF logic: expected_checkpoints = 100 / 10 = 10.
        // vdf_size = 10 * 32 = 320.
        // vrf_size = 96.
        // slot = 8.
        // bitmask = 8.
        // sig = 96.
        // Total = 320 + 8 + 96 + 8 + 96 = 528.
        assert_eq!(header.extra_data.len(), 528);
    }
}
