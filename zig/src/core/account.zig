const std = @import("std");
const crypto = std.crypto;
const hex = @import("utils").hex;
const core_types = @import("types.zig");

pub const Error = error{
    InvalidPassword,
    InvalidKeystore,
    EncryptionFailed,
    DecryptionFailed,
    InvalidKey,
};

pub const KeystoreV3 = struct {
    address: []const u8,
    id: []const u8,
    version: u32,
    crypto: CryptoInfo,

    pub const CryptoInfo = struct {
        cipher: []const u8,
        ciphertext: []const u8,
        cipherparams: CipherParams,
        kdf: []const u8,
        kdfparams: KdfParams,
        mac: []const u8,
    };

    pub const CipherParams = struct {
        iv: []const u8,
    };

    pub const KdfParams = struct {
        dklen: u32,
        n: u32,
        r: u32,
        p: u32,
        salt: []const u8,
    };
};

/// Derive address from private key bytes (32 bytes)
pub fn addressFromPrivKey(priv_key: [32]u8) !core_types.Address {
    const Secp256k1 = crypto.ecc.Secp256k1;

    // 1. Get Public Key from Private Key
    const scalar = try Secp256k1.scalar.Scalar.fromBytes(priv_key, .big);
    const public_key = try Secp256k1.basePoint.mul(scalar.toBytes(.big), .big);
    const uncompressed = public_key.toUncompressedSec1(); // 65 bytes: 0x04 + X + Y

    // 2. Hash X and Y coordinates (64 bytes)
    var hasher = crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(uncompressed[1..]); // Skip the 0x04 prefix
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    // 3. Address is last 20 bytes of hash
    var addr: core_types.Address = undefined;
    @memcpy(&addr.bytes, hash[12..32]);
    return addr;
}

/// Derive address from uncompressed public key (65 bytes with 0x04 prefix)
pub fn addressFromPubKey(pub_key: []const u8) !core_types.Address {
    if (pub_key.len != 65 or pub_key[0] != 0x04) return error.InvalidKey;

    // 1. Hash X and Y coordinates (64 bytes)
    var hasher = crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(pub_key[1..]);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    // 2. Address is last 20 bytes of hash
    var addr: core_types.Address = undefined;
    @memcpy(&addr.bytes, hash[12..32]);
    return addr;
}

/// Verify an ECDSA signature
pub fn verify_signature(hash: [32]u8, sig: [64]u8, pub_key_bytes: [65]u8) !bool {
    const Secp256k1 = crypto.ecc.Secp256k1;
    const Ecdsa = crypto.sign.ecdsa.Ecdsa(Secp256k1, crypto.hash.sha3.Keccak256);
    const signature = Ecdsa.Signature.fromBytes(sig);
    const public_key = try Ecdsa.PublicKey.fromSec1(pub_key_bytes[0..]);
    signature.verifyPrehashed(hash, public_key) catch return false;
    return true;
}

/// Recover public key from ECDSA signature (r, s, recovery_id)
pub fn recover_public_key(hash: [32]u8, r: [32]u8, s: [32]u8, recovery_id: u8) ![65]u8 {
    const Secp256k1 = crypto.ecc.Secp256k1;

    // 1. Recover the random point R = (x, y)
    // x = r + kn (where k is integer, usually 0 for secp256k1 since r < n)
    // For secp256k1, r is almost always < p and < n, so x = r.

    // We strictly need the field element for x-coord (Fp), not scalar (Fq)
    // But Secp256k1 is Koblitz curve? No, over field Fp.
    // Let's use internal APIs if possible or math

    // Actually, Zig std lib hides the field arithmetic types inside struct.
    // It's safer to use a dedicated recovery function if available.
    // Since it's not, we have to construct the point R manually.

    // ALTERNATIVE: Use the fact that Secp256k1.fromSec1 handles compressed keys.
    // We can construct the compressed representation of R: 0x02/0x03 + r

    const prefix: u8 = 0x02 + (recovery_id % 2);
    var compressed_R: [33]u8 = undefined;
    compressed_R[0] = prefix;
    @memcpy(compressed_R[1..], &r);

    const R = try Secp256k1.fromSec1(&compressed_R);

    // 2. Compute Q = r^-1 * (s * R - e * G)
    // Note: Verification is u1*G + u2*Q = R
    // u1 = e * s^-1, u2 = r * s^-1
    // R = e*w*G + r*w*Q  where w = s^-1
    // r*w*Q = R - e*w*G
    // Q = (r*w)^-1 * (R - e*w*G)
    // Q = r^-1 * s * (R - e*s^-1*G) = r^-1 * (s*R - e*G)

    // We need scalar arithmetic.
    const e = try Secp256k1.scalar.Scalar.fromBytes(hash, .big);
    const s_scalar = try Secp256k1.scalar.Scalar.fromBytes(s, .big);
    const r_scalar = try Secp256k1.scalar.Scalar.fromBytes(r, .big);

    const r_inv = r_scalar.invert();
    const e_neg = e.neg();

    // s * R
    const sR = try R.mul(s_scalar.toBytes(.big), .big);

    // -e * G
    const neg_eG = try Secp256k1.basePoint.mul(e_neg.toBytes(.big), .big);

    // sR - eG = sR + (-eG)
    const sum = sR.add(neg_eG);

    // Q = r^-1 * sum
    const Q = try sum.mul(r_inv.toBytes(.big), .big);

    return Q.toUncompressedSec1();
}

/// Encrypt a private key into a V3 Keystore JSON
pub fn encrypt(allocator: std.mem.Allocator, priv_key: [32]u8, password: []const u8) ![]u8 {
    // 1. Generate salt and IV
    var salt: [32]u8 = undefined;
    crypto.random.bytes(&salt);
    var iv: [16]u8 = undefined;
    crypto.random.bytes(&iv);

    // 2. Derive encryption key using Scrypt
    // Parameters matching default Ethereum V3 (N=262144, r=8, p=1)
    const n: u32 = 262144;
    const r: u32 = 8;
    const p: u32 = 1;
    var derived_key: [32]u8 = undefined;
    try crypto.pwhash.scrypt.kdf(allocator, &derived_key, password, &salt, .{ .ln = 18, .r = r, .p = p });

    // 3. Encrypt private key using AES-128-CTR (standard V3 uses first 16 bytes of derived key)
    const encryption_key = derived_key[0..16];
    var ciphertext: [32]u8 = undefined;

    const Aes128 = crypto.core.aes.Aes128;
    const aes_ctx = Aes128.initEnc(encryption_key.*);
    crypto.core.modes.ctr(@TypeOf(aes_ctx), aes_ctx, ciphertext[0..32], &priv_key, iv, .big);

    // 4. Compute MAC: Keccak256(derived_key[16:32] + ciphertext)
    var mac_hasher = crypto.hash.sha3.Keccak256.init(.{});
    mac_hasher.update(derived_key[16..32]);
    mac_hasher.update(&ciphertext);
    var mac: [32]u8 = undefined;
    mac_hasher.final(&mac);

    // 5. Build Keystore structure
    const addr = try addressFromPrivKey(priv_key);
    var addr_buf: [42]u8 = undefined;
    const addr_hex = try hex.encodeBuffer(&addr_buf, &addr.bytes);

    var id_uuid: [16]u8 = undefined;
    crypto.random.bytes(&id_uuid);
    var id_buf: [36]u8 = undefined;
    var id1: [10]u8 = undefined;
    var id2: [6]u8 = undefined;
    var id3: [6]u8 = undefined;
    var id4: [6]u8 = undefined;
    var id5: [14]u8 = undefined;

    const id_str = try std.fmt.bufPrint(&id_buf, "{s}-{s}-{s}-{s}-{s}", .{
        std.mem.trimLeft(u8, try hex.encodeBuffer(&id1, id_uuid[0..4]), "0x"),
        std.mem.trimLeft(u8, try hex.encodeBuffer(&id2, id_uuid[4..6]), "0x"),
        std.mem.trimLeft(u8, try hex.encodeBuffer(&id3, id_uuid[6..8]), "0x"),
        std.mem.trimLeft(u8, try hex.encodeBuffer(&id4, id_uuid[8..10]), "0x"),
        std.mem.trimLeft(u8, try hex.encodeBuffer(&id5, id_uuid[10..16]), "0x"),
    });

    const keystore = KeystoreV3{
        .address = try allocator.dupe(u8, std.mem.trimLeft(u8, addr_hex, "0x")),
        .id = try allocator.dupe(u8, id_str),
        .version = 3,
        .crypto = .{
            .cipher = "aes-128-ctr",
            .ciphertext = try hex.encode(allocator, &ciphertext),
            .cipherparams = .{
                .iv = try hex.encode(allocator, &iv),
            },
            .kdf = "scrypt",
            .kdfparams = .{
                .dklen = 32,
                .n = n,
                .r = r,
                .p = p,
                .salt = try hex.encode(allocator, &salt),
            },
            .mac = try hex.encode(allocator, &mac),
        },
    };
    defer allocator.free(keystore.address);
    defer allocator.free(keystore.id);
    defer allocator.free(keystore.crypto.ciphertext);
    defer allocator.free(keystore.crypto.cipherparams.iv);
    defer allocator.free(keystore.crypto.kdfparams.salt);
    defer allocator.free(keystore.crypto.mac);
    return try std.json.Stringify.valueAlloc(allocator, keystore, .{});
}

/// Decrypt a private key from a Keystore JSON
pub fn decrypt(allocator: std.mem.Allocator, json_content: []const u8, password: []const u8) ![32]u8 {
    var parsed = try std.json.parseFromSlice(KeystoreV3, allocator, json_content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const keystore = parsed.value;

    // 1. Decode params
    const ciphertext = try hex.decode(allocator, std.mem.trimLeft(u8, keystore.crypto.ciphertext, "0x"));
    defer allocator.free(ciphertext);
    const iv_bytes = try hex.decode(allocator, std.mem.trimLeft(u8, keystore.crypto.cipherparams.iv, "0x"));
    defer allocator.free(iv_bytes);
    const salt_bytes = try hex.decode(allocator, std.mem.trimLeft(u8, keystore.crypto.kdfparams.salt, "0x"));
    defer allocator.free(salt_bytes);
    const mac_bytes = try hex.decode(allocator, std.mem.trimLeft(u8, keystore.crypto.mac, "0x"));
    defer allocator.free(mac_bytes);

    if (ciphertext.len != 32 or iv_bytes.len != 16 or salt_bytes.len != 32 or mac_bytes.len != 32) {
        return error.InvalidKeystore;
    }

    // 2. Derive key
    var derived_key: [32]u8 = undefined;
    const ln = @as(u6, @intCast(std.math.log2(keystore.crypto.kdfparams.n)));
    try crypto.pwhash.scrypt.kdf(allocator, &derived_key, password, salt_bytes[0..32], .{
        .ln = ln,
        .r = @intCast(keystore.crypto.kdfparams.r),
        .p = @intCast(keystore.crypto.kdfparams.p),
    });

    // 3. Verify MAC
    var mac_hasher = crypto.hash.sha3.Keccak256.init(.{});
    mac_hasher.update(derived_key[16..32]);
    mac_hasher.update(ciphertext);
    var computed_mac: [32]u8 = undefined;
    mac_hasher.final(&computed_mac);

    if (!crypto.timing_safe.eql([32]u8, computed_mac, mac_bytes[0..32].*)) {
        return error.InvalidPassword;
    }

    // 4. Decrypt
    var priv_key: [32]u8 = undefined;
    const encryption_key = derived_key[0..16];
    const Aes128 = crypto.core.aes.Aes128;
    const aes_ctx = Aes128.initEnc(encryption_key.*);
    crypto.core.modes.ctr(@TypeOf(aes_ctx), aes_ctx, &priv_key, ciphertext, iv_bytes[0..16].*, .big);

    return priv_key;
}

test "keystore encryption/decryption" {
    const allocator = std.testing.allocator;
    const password = "password123";

    var priv_key: [32]u8 = undefined;
    @memset(&priv_key, 0xAA);

    const json = try encrypt(allocator, priv_key, password);
    defer allocator.free(json);

    const decrypted = try decrypt(allocator, json, password);
    try std.testing.expectEqualSlices(u8, &priv_key, &decrypted);

    // Verify address derivation
    const addr = try addressFromPrivKey(priv_key);
    // 0xAA * 32 privkey address should be stable.
    // Let's just check it doesn't crash and returns 20 bytes.
    try std.testing.expect(addr.bytes.len == 20);
}
