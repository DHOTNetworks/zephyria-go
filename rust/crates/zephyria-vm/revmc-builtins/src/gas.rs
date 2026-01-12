//! Stub gas calculation functions for revmc-builtins
//!
//! These are temporary stubs until the full gas calculation logic is implemented.

use primitives::{hardfork::SpecId, U256};

// Re-export everything from interpreter::gas
pub use interpreter::gas::*;

/// Warm/cold storage access cost
#[inline]
pub const fn warm_cold_cost(is_cold: bool) -> u64 {
    if is_cold {
        COLD_ACCOUNT_ACCESS_COST
    } else {
        WARM_STORAGE_READ_COST
    }
}

/// Warm/cold cost with EIP-7702 delegation
#[inline]
pub const fn warm_cold_cost_with_delegation(is_cold: bool) -> u64 {
    warm_cold_cost(is_cold)
}

/// EXTCODECOPY cost calculation
#[inline]
pub fn extcodecopy_cost(_spec_id: SpecId, len: u64, is_cold: bool) -> Option<u64> {
    let base_cost = warm_cold_cost(is_cold);
    let copy_cost = cost_per_word(len, COPY)?;
    Some(base_cost + copy_cost)
}

/// SLOAD cost calculation
#[inline]
pub const fn sload_cost(_spec_id: SpecId, is_cold: bool) -> u64 {
    warm_cold_cost(is_cold)
}

/// SSTORE cost calculation (simplified)
#[inline]
pub const fn sstore_cost(
    _spec_id: SpecId,
    _original: &U256,
    _current: &U256,
    _new: &U256,
    gas: u64,
    is_cold: bool,
) -> Option<u64> {
    let base_cost = if is_cold {
        COLD_SLOAD_COST
    } else {
        WARM_STORAGE_READ_COST
    };

    // Simplified: just return base cost
    // Full implementation would check for storage changes
    if gas < base_cost {
        return None;
    }
    Some(base_cost)
}

/// SSTORE refund calculation (simplified)
#[inline]
pub const fn sstore_refund(
    _spec_id: SpecId,
    _original: &U256,
    _current: &U256,
    _new: &U256,
) -> i64 {
    // Simplified: no refund
    0
}

/// Cost per word calculation
#[inline]
pub const fn cost_per_word(len: u64, word_cost: u64) -> Option<u64> {
    let words = (len + 31) / 32;
    words.checked_mul(word_cost)
}

/// Initcode cost (EIP-3860)
#[inline]
pub const fn initcode_cost(len: u64) -> Option<u64> {
    cost_per_word(len, INITCODE_WORD_COST)
}

/// CREATE2 cost calculation
#[inline]
pub const fn create2_cost(len: u64) -> Option<u64> {
    cost_per_word(len, KECCAK256WORD)
}

/// CALL cost calculation (simplified)
#[inline]
pub const fn call_cost(
    _spec_id: SpecId,
    transfers_value: bool,
    is_cold: bool,
    _is_new_account: bool,
) -> Option<u64> {
    let mut cost = warm_cold_cost(is_cold);

    if transfers_value {
        cost += CALLVALUE;
    }

    Some(cost)
}

/// Minimum gas for callee
pub const MIN_CALLEE_GAS: u64 = 2300;

/// SELFDESTRUCT gas cost
pub const SELFDESTRUCT: u64 = 5000;

// Gas constants
pub const WARM_STORAGE_READ_COST: u64 = 100;
pub const COLD_ACCOUNT_ACCESS_COST: u64 = 2600;
pub const COLD_SLOAD_COST: u64 = 2100;
pub const CALLVALUE: u64 = 9000;
pub const COPY: u64 = 3;
pub const KECCAK256WORD: u64 = 6;
pub const INITCODE_WORD_COST: u64 = 2;

/// Dynamic EXP cost
#[inline]
pub fn dyn_exp_cost(spec_id: SpecId, exponent: U256) -> Option<u64> {
    if exponent == U256::ZERO {
        return Some(0);
    }

    // Calculate number of bytes in exponent
    let byte_size = (256 - exponent.leading_zeros()) / 8 + 1;
    let gas_per_byte = if spec_id >= SpecId::SPURIOUS_DRAGON {
        50
    } else {
        10
    };

    Some(byte_size as u64 * gas_per_byte)
}

/// Dynamic KECCAK256 cost
#[inline]
pub const fn dyn_keccak256_cost(len: u64) -> Option<u64> {
    cost_per_word(len, KECCAK256WORD)
}

/// Dynamic VERYLOWCOPY cost (CALLDATACOPY, CODECOPY, RETURNDATACOPY)
#[inline]
pub const fn dyn_verylowcopy_cost(len: u64) -> Option<u64> {
    cost_per_word(len, COPY)
}

/// Dynamic LOG cost
#[inline]
pub const fn dyn_log_cost(len: u64) -> Option<u64> {
    const LOGDATA: u64 = 8;
    len.checked_mul(LOGDATA)
}

/// SELFDESTRUCT cost calculation
#[inline]
pub const fn selfdestruct_cost(_spec_id: SpecId, _is_cold: bool, _is_new_account: bool) -> u64 {
    SELFDESTRUCT
}
