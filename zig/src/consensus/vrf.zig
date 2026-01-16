const std = @import("std");
const core = @import("core");
// Import blst module. build.zig ensures this is available.
const blst_mod = @import("blst");
const c = blst_mod.c;

const VRF_DST = "ZEPHYRIA_VRF_DST_V01";

pub const VRF = struct {
    /// Prove generates a VRF proof.
    /// Input: Secret Key bytes (32 bytes scalar), Seed Input
    /// Output: Proof (48 bytes compressed G1 or 96 bytes uncompressed? - sticking to 48 compressed for now as it matches G1)
    pub fn prove(sk_bytes: []const u8, input: []const u8) ![48]u8 {
        if (sk_bytes.len != 32) return error.InvalidSecretKeyLength;

        // 1. Hash to G1
        var p1: c.blst_p1 = undefined;
        // void blst_hash_to_g1(blst_p1 *out, const byte *msg, size_t msg_len, const byte *dst, size_t dst_len, const byte *aug, size_t aug_len);
        c.blst_hash_to_g1(&p1, input.ptr, @as(usize, input.len), VRF_DST.ptr, @as(usize, VRF_DST.len), null, 0);

        // 2. Deserialize Scalar (SK)
        var sk: c.blst_scalar = undefined;
        // void blst_scalar_from_bendian(blst_scalar *out, const byte *in);
        c.blst_scalar_from_bendian(&sk, sk_bytes.ptr);

        // 3. Scalar Multiplication: res = p1 * sk
        var res: c.blst_p1 = undefined;
        // void blst_p1_mult(blst_p1 *out, const blst_p1 *p, const blst_scalar *scalar, size_t nbits);
        // nbits is usually 255 or 256 for BLS12-381 scalar?
        // documentation says: "nbits is the number of bits in the scalar, can be less than 255"
        // standard is 255 usually for safer scalar mult implementation if variable time?
        // Or 8 * 32 = 256.
        // Let's use 256.
        c.blst_p1_mult(&res, &p1, @ptrCast(&sk), 256);

        // 4. Compress/Serialize to Bytes (G1 compressed is 48 bytes)
        var out_bytes: [48]u8 = undefined;
        // void blst_p1_compress(byte *out, const blst_p1 *in);
        c.blst_p1_compress(&out_bytes, &res);

        // Return heap allocated slice because the API expects ![]u8?
        // Actually, the caller of this function in Zelius simulation probably expects a slice they can manage or just copy.
        // For efficiency, maybe return [48]u8?
        // But the signature in previous vrf.zig was ![]u8.
        // I'll update it to return [48]u8 to be more precise, or return a slice from allocator if needed.
        // But here I don't have allocator.
        // I will return [48]u8 and let caller handle it.
        // Wait, current signature is `![]u8`.
        // I'll cheat and use a static buffer dupe if I had allocator, but I don't.
        // I will change return type to `![48]u8`.
        return out_bytes;
    }

    // CheckEligibility logic (verify proof < threshold)
    // func (e *ZeliusEngine) CheckEligibility(seed []byte, slot uint64, sk *big.Int, stake *big.Int, totalStake *big.Int) (bool, []byte, error)
    pub fn check_eligibility(sk_bytes: []const u8, seed: []const u8, slot: u64, stake: u256, total_stake: u256) !struct { bool, [48]u8 } {
        var input_buf: [40]u8 = undefined; // 32 bytes seed + 8 bytes slot
        if (seed.len != 32) return error.InvalidSeedLength;

        // Combine seed + slot like Go code
        // Go: input := append(seed, binary.BigEndian.PutUint64(slot)...)
        @memcpy(input_buf[0..32], seed);
        std.mem.writeInt(u64, input_buf[32..40], slot, .big);

        const proof = try prove(sk_bytes, &input_buf);

        // Verify < Threshold
        // Threshold = 2^256 * Stake / TotalStake
        // But Proof is a point on curve. We need to hash it to a scalar/number to compare?
        // Go code `CheckEligibility`:
        //   proof, _ := e.VRFProve(sk, input)
        //   hash := crypto.Keccak256(proof)
        //   val := new(big.Int).SetBytes(hash)
        //   limit := new(big.Int).Mul(max, stake)
        //   limit.Div(limit, totalStake)
        //   return val.Cmp(limit) < 0

        var hash_buf: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&proof, &hash_buf, .{});

        // Easier: Use u256 from integer types.
        const val_u256 = std.mem.readInt(u256, &hash_buf, .big);

        // limit = (2^256 - 1) * stake / total_stake
        // Max u256
        const max = ~@as(u256, 0);

        // We need u512 for multiplication to avoid overflow
        const stake_ext = @as(u512, stake);
        const max_ext = @as(u512, max);
        const num = max_ext * stake_ext;
        const limit = @as(u256, @truncate(num / @as(u512, total_stake)));

        return .{ val_u256 < limit, proof };
    }
};
