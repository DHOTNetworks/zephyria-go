use blst::BLST_ERROR;

pub struct VRF;

pub const DST: &[u8] = b"ZEPHYRIA-VRF";

impl VRF {
    /// Prove generates a VRF proof: H(input) * sk (G1)
    pub fn prove(secret_key_bytes: &[u8], input: &[u8]) -> Result<Vec<u8>, String> {
        sign_g1(secret_key_bytes, input, DST)
    }

    /// Verify checks the VRF proof.
    /// Expects:
    /// - public_key_bytes: 96 bytes (G2) if using min_sig (Sig in G1)
    /// - proof: 48 bytes (G1)
    pub fn verify(public_key_bytes: &[u8], input: &[u8], proof: &[u8]) -> Result<bool, String> {
        use blst::min_sig::{PublicKey, Signature};

        let sig = Signature::from_bytes(proof).map_err(|e| format!("Invalid Proof: {:?}", e))?;
        let pk =
            PublicKey::from_bytes(public_key_bytes).map_err(|e| format!("Invalid PK: {:?}", e))?;

        if sig.verify(true, input, DST, &[], &pk, true) == BLST_ERROR::BLST_SUCCESS {
            Ok(true)
        } else {
            Ok(false)
        }
    }
}

/// Helper for HashToG1 * sk (G1 Signature / VRF Proof)
pub fn sign_g1(sk_bytes: &[u8], msg: &[u8], dst: &[u8]) -> Result<Vec<u8>, String> {
    // blst::min_sig uses HashToG1 for signing.
    use blst::min_sig::SecretKey;
    let sk = SecretKey::from_bytes(sk_bytes).map_err(|e| format!("{:?}", e))?;
    let sig = sk.sign(msg, dst, &[]);
    Ok(sig.to_bytes().to_vec()) // 48 bytes compressed G1
}

/// Helper for HashToG2 * sk (G2 Signature / Vote)
pub fn sign_g2(sk_bytes: &[u8], msg: &[u8], dst: &[u8]) -> Result<Vec<u8>, String> {
    // blst::min_pk uses HashToG2 for signing.
    use blst::min_pk::SecretKey;
    let sk = SecretKey::from_bytes(sk_bytes).map_err(|e| format!("{:?}", e))?;
    let sig = sk.sign(msg, dst, &[]);
    Ok(sig.to_bytes().to_vec()) // 96 bytes compressed G2
}
