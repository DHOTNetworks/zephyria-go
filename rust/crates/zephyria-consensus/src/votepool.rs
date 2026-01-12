use blst::min_sig::{AggregateSignature, PublicKey, Signature};
use blst::BLST_ERROR;
use parking_lot::RwLock;
use std::collections::HashMap;
use zephyria_types::{Hash, Validator, Vote, U256};

/// VotePool manages receiving and aggregating votes.
pub struct VotePool {
    // BlockHash -> ValIndex -> Vote
    votes: RwLock<HashMap<Hash, HashMap<u64, Vote>>>,
}

impl VotePool {
    pub fn new() -> Self {
        Self {
            votes: RwLock::new(HashMap::new()),
        }
    }

    /// Adds a vote if valid.
    /// Requires active_validators to verify index and signature.
    pub fn add_vote(&self, vote: Vote, validators: &[Validator]) -> bool {
        let mut votes_lock = self.votes.write();

        // 1. Check duplicate
        let block_votes = votes_lock
            .entry(vote.block_hash)
            .or_insert_with(HashMap::new);
        if block_votes.contains_key(&vote.validator_index) {
            return false;
        }

        // 2. Validate Index
        if vote.validator_index as usize >= validators.len() {
            return false;
        }
        let validator = &validators[vote.validator_index as usize];

        // 3. Verify Signature
        if !self.verify_signature(&vote, &validator.bls_pub_key) {
            return false;
        }

        // 4. Store
        block_votes.insert(vote.validator_index, vote);
        true
    }

    /// Verifies single vote signature.
    fn verify_signature(&self, vote: &Vote, pub_key_bytes: &[u8]) -> bool {
        let pk = match PublicKey::from_bytes(pub_key_bytes) {
            Ok(pk) => pk,
            Err(_) => return false,
        };

        let sig = match Signature::from_bytes(&vote.signature) {
            Ok(s) => s,
            Err(_) => return false,
        };

        // MST: Message to sign.
        // We'll use vote.block_hash as message for now.
        let msg = vote.block_hash.as_slice();
        let dst = b"ZEPHYRIA-VOTE"; // Domain Separation Tag

        sig.verify(true, msg, dst, &[], &pk, true) == BLST_ERROR::BLST_SUCCESS
    }

    /// Checks if a block has > 2/3 stake votes.
    /// Returns (is_quorum, agg_sig, bitmask)
    pub fn check_quorum(
        &self,
        block_hash: Hash,
        validators: &[Validator],
    ) -> (bool, Vec<u8>, Vec<u8>) {
        let votes_read = self.votes.read();
        let votes = match votes_read.get(&block_hash) {
            Some(v) => v,
            None => return (false, vec![], vec![]),
        };

        let mut total_stake = U256::ZERO;
        for v in validators {
            total_stake += v.stake;
        }

        let mut voted_stake = U256::ZERO;
        let mut bitmask = vec![0u8; (validators.len() + 7) / 8];

        let mut sigs_to_agg: Vec<Signature> = Vec::new();

        for (idx, vote) in votes {
            let idx = *idx as usize;
            if idx >= validators.len() {
                continue;
            }
            voted_stake += validators[idx].stake;

            // Update bitmask
            bitmask[idx / 8] |= 1 << (idx % 8);

            // Parse SIG for aggregation
            if let Ok(sig) = Signature::from_bytes(&vote.signature) {
                sigs_to_agg.push(sig);
            }
        }

        // Threshold = 2/3 Total
        // (total * 2) / 3
        let threshold = (total_stake * U256::from(2)) / U256::from(3);

        if voted_stake > threshold && !sigs_to_agg.is_empty() {
            // Aggregate
            let refs: Vec<&Signature> = sigs_to_agg.iter().collect();
            // AggregateSignature::aggregate expects &[&Signature] and boolean for "check group"
            if let Ok(agg) = AggregateSignature::aggregate(&refs, true) {
                return (true, agg.to_signature().to_bytes().to_vec(), bitmask);
            }
        }

        (false, vec![], vec![])
    }

    pub fn prune(&self, min_view: u64) {
        let mut votes = self.votes.write();
        votes.retain(|_, block_votes| {
            // Check first vote view
            if let Some(v) = block_votes.values().next() {
                v.view >= min_view
            } else {
                false // empty map, prune
            }
        });
    }
}
