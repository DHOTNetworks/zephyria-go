use sha2::{Digest, Sha256};
use std::sync::mpsc;
use std::thread;

pub struct VDF;

impl VDF {
    pub fn new() -> Self {
        Self
    }

    /// Compute performs sequential hashing on the input for 'iterations' count.
    /// Output = SHA256^iterations(Input)
    pub fn compute(&self, input: &[u8], iterations: u64) -> Vec<u8> {
        let mut current_hash = input.to_vec();
        for _ in 0..iterations {
            let mut hasher = Sha256::new();
            hasher.update(&current_hash);
            current_hash = hasher.finalize().to_vec();
        }
        current_hash
    }

    /// Verify checks if the output matches the input after 'iterations' hashes.
    pub fn verify(&self, input: &[u8], output: &[u8], iterations: u64) -> bool {
        let computed = self.compute(input, iterations);
        computed == output
    }

    /// ComputeWithCheckpoints returns checkpoints every 'interval' iterations.
    pub fn compute_with_checkpoints(&self, input: &[u8], iterations: u64, interval: u64) -> Vec<Vec<u8>> {
        if interval == 0 {
            return vec![];
        }
        let cap = (iterations / interval) as usize;
        let mut results = Vec::with_capacity(cap);
        let mut current_hash = input.to_vec();

        for i in 1..=iterations {
            let mut hasher = Sha256::new();
            hasher.update(&current_hash);
            current_hash = hasher.finalize().to_vec();

            if i % interval == 0 {
                results.push(current_hash.clone());
            }
        }
        results
    }

    /// VerifyParallel verifies a chain of checkpoints in parallel.
    pub fn verify_parallel(&self, input: &[u8], checkpoints: &[Vec<u8>], interval: u64) -> bool {
        if checkpoints.is_empty() {
            return false;
        }

        let (tx, rx) = mpsc::channel();
        let mut segments = Vec::new();

        // Input -> CP[0]
        segments.push((input.to_vec(), checkpoints[0].clone()));
        // CP[i-1] -> CP[i]
        for i in 1..checkpoints.len() {
            segments.push((checkpoints[i - 1].clone(), checkpoints[i].clone()));
        }

        let count = segments.len();

        for (start, end) in segments {
            let tx = tx.clone();
            let interval = interval;
            thread::spawn(move || {
                let mut current = start;
                for _ in 0..interval {
                    let mut hasher = Sha256::new();
                    hasher.update(&current);
                    current = hasher.finalize().to_vec();
                }
                tx.send(current == end).unwrap();
            });
        }

        for _ in 0..count {
            match rx.recv() {
                Ok(true) => continue,
                Ok(false) => return false,
                Err(_) => return false,
            }
        }

        true
    }
}
