const std = @import("std");
const types = @import("types.zig");
const rlp = @import("encoding").rlp;
const crypto = std.crypto;

/// RLP-encoded transaction structure (without 'from' field)
const RlpTransaction = struct {
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    to: ?types.Address,
    value: u256,
    data: []const u8,
    v: u256,
    r: u256,
    s: u256,
};

/// Decode a raw RLP-encoded transaction and recover the sender address
pub fn decodeTransaction(allocator: std.mem.Allocator, raw_bytes: []const u8) !types.Transaction {
    // Decode the RLP structure (9 fields)
    const rlp_tx = try rlp.decode(allocator, RlpTransaction, raw_bytes);

    // Recover sender address from signature
    const from_addr = try recoverSender(allocator, rlp_tx, raw_bytes);

    // Construct full transaction with recovered 'from' address
    return types.Transaction{
        .nonce = rlp_tx.nonce,
        .gas_price = rlp_tx.gas_price,
        .gas_limit = rlp_tx.gas_limit,
        .from = from_addr,
        .to = rlp_tx.to,
        .value = rlp_tx.value,
        .data = rlp_tx.data,
        .v = rlp_tx.v,
        .r = rlp_tx.r,
        .s = rlp_tx.s,
    };
}

/// Recover the sender address from transaction signature
const account = @import("account.zig");

/// RLP-encoded transaction for signing (EIP-155 Legacy)
const LegacySigningData = struct {
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    to: ?types.Address,
    value: u256,
    data: []const u8,
    chain_id: u64,
    zero1: u8 = 0,
    zero2: u8 = 0,
};

const LegacySigningDataPreEIP155 = struct {
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    to: ?types.Address,
    value: u256,
    data: []const u8,
};

/// Recover the sender address from transaction signature
fn recoverSender(allocator: std.mem.Allocator, tx: RlpTransaction, raw_bytes: []const u8) !types.Address {
    _ = raw_bytes; // Not needed if we reconstruct signing data

    // 1. Determine ChainID and RecoveryID (v)
    // EIP-155: v = chain_id * 2 + 35 + recovery_id
    // Legacy:  v = 27 + recovery_id

    var recovery_id: u8 = 0;
    var chain_id: u64 = 0;
    var is_eip155 = false;

    const v_val = @as(u64, @truncate(tx.v)); // v fits in u64 usually

    if (v_val >= 35) {
        // EIP-155
        is_eip155 = true;
        chain_id = (v_val - 35) / 2;
        recovery_id = @as(u8, @intCast(v_val - 35 - 2 * chain_id));
    } else if (v_val >= 27) {
        // Pre-EIP-155
        recovery_id = @as(u8, @intCast(v_val - 27));
    } else {
        return error.InvalidSignature; // v must be at least 27
    }

    // 2. Encode Signing Data
    var hash: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});

    if (is_eip155) {
        const signing_data = LegacySigningData{
            .nonce = tx.nonce,
            .gas_price = tx.gas_price,
            .gas_limit = tx.gas_limit,
            .to = tx.to,
            .value = tx.value,
            .data = tx.data,
            .chain_id = chain_id,
        };
        const encoded = try rlp.encode(allocator, signing_data);
        defer allocator.free(encoded);
        hasher.update(encoded);
    } else {
        const signing_data = LegacySigningDataPreEIP155{
            .nonce = tx.nonce,
            .gas_price = tx.gas_price,
            .gas_limit = tx.gas_limit,
            .to = tx.to,
            .value = tx.value,
            .data = tx.data,
        };
        const encoded = try rlp.encode(allocator, signing_data);
        defer allocator.free(encoded);
        hasher.update(encoded);
    }
    hasher.final(&hash);

    // 3. Extract r and s
    var r: [32]u8 = undefined;
    var s: [32]u8 = undefined;
    std.mem.writeInt(u256, &r, tx.r, .big);
    std.mem.writeInt(u256, &s, tx.s, .big);

    // 4. Recover Public Key and Address
    const pub_key = try account.recover_public_key(hash, r, s, recovery_id);
    return account.addressFromPubKey(pub_key[0..]);
}

/// Recover sender address from a Transaction struct
pub fn recoverFromTx(allocator: std.mem.Allocator, tx: types.Transaction) !types.Address {
    // Determine Chain ID and Recovery ID
    var chain_id: u64 = 0;
    var recovery_id: u8 = 0;
    var is_eip155 = false;

    // EIP-155: v = chain_id * 2 + 35 + recovery_id
    // Pre-EIP-155: v = 27 + recovery_id
    const v_low = @as(u64, @truncate(std.math.cast(u64, tx.v) orelse 0));

    if (v_low >= 35) {
        is_eip155 = true;
        chain_id = (v_low - 35) / 2;
        recovery_id = @as(u8, @intCast(v_low - 35 - 2 * chain_id));
    } else if (v_low >= 27) {
        recovery_id = @as(u8, @intCast(v_low - 27));
    } else {
        return error.InvalidSignature; // v must be >= 27
    }

    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    var hash: [32]u8 = undefined;

    if (is_eip155) {
        const signing_data = LegacySigningData{
            .nonce = tx.nonce,
            .gas_price = tx.gas_price,
            .gas_limit = tx.gas_limit,
            .to = tx.to,
            .value = tx.value,
            .data = tx.data,
            .chain_id = chain_id,
        };
        const encoded = try rlp.encode(allocator, signing_data);
        defer allocator.free(encoded);
        hasher.update(encoded);
    } else {
        const signing_data = LegacySigningDataPreEIP155{
            .nonce = tx.nonce,
            .gas_price = tx.gas_price,
            .gas_limit = tx.gas_limit,
            .to = tx.to,
            .value = tx.value,
            .data = tx.data,
        };
        const encoded = try rlp.encode(allocator, signing_data);
        defer allocator.free(encoded);
        hasher.update(encoded);
    }
    hasher.final(&hash);

    // Extract r and s
    var r: [32]u8 = undefined;
    var s: [32]u8 = undefined;
    std.mem.writeInt(u256, &r, tx.r, .big);
    std.mem.writeInt(u256, &s, tx.s, .big);

    const pub_key = try account.recover_public_key(hash, r, s, recovery_id);
    return account.addressFromPubKey(pub_key[0..]);
}
