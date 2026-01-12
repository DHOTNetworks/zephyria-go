#![doc = include_str!("../README.md")]
#![allow(missing_docs, clippy::missing_safety_doc)]
#![cfg_attr(not(test), warn(unused_extern_crates))]
#![cfg_attr(docsrs, feature(doc_cfg, doc_auto_cfg))]
#![cfg_attr(not(feature = "std"), no_std)]

//! REVMC Builtins - Minimal Stub Implementation
//!
//! This is a minimal stub implementation of revmc-builtins that compiles
//! but does not provide full functionality. The full implementation requires
//! significant refactoring to work with the trait-based interpreter architecture.
//!
//! TODO: Implement full builtins when needed for JIT compilation.

extern crate alloc;

use alloc::{boxed::Box, vec::Vec};
use interpreter::InstructionResult;
use primitives::{hardfork::SpecId, KECCAK_EMPTY, U256};
use revmc_context::{EvmContext, EvmWord};

pub mod gas;

#[cfg(feature = "ir")]
mod ir;
#[cfg(feature = "ir")]
pub use ir::*;

#[macro_use]
mod macros;

mod utils;
use utils::*;

// Minimal builtin implementations

#[no_mangle]
pub unsafe extern "C-unwind" fn __revmc_builtin_panic(data: *const u8, len: usize) -> ! {
    let msg = core::str::from_utf8_unchecked(core::slice::from_raw_parts(data, len));
    panic!("{msg}");
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_addmod(rev![a, b, c]: &mut [EvmWord; 3]) {
    *c = a.to_u256().add_mod(b.to_u256(), c.to_u256()).into();
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_mulmod(rev![a, b, c]: &mut [EvmWord; 3]) {
    *c = a.to_u256().mul_mod(b.to_u256(), c.to_u256()).into();
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_exp(
    ecx: &mut EvmContext<'_>,
    rev![base, exponent_ptr]: &mut [EvmWord; 2],
    spec_id: SpecId,
) -> InstructionResult {
    let exponent = exponent_ptr.to_u256();
    gas_opt!(ecx, gas::dyn_exp_cost(spec_id, exponent));
    *exponent_ptr = base.to_u256().pow(exponent).into();
    InstructionResult::Continue
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_keccak256(
    ecx: &mut EvmContext<'_>,
    rev![offset, len_ptr]: &mut [EvmWord; 2],
) -> InstructionResult {
    let len = try_into_usize!(len_ptr);
    *len_ptr = EvmWord::from_be_bytes(if len == 0 {
        KECCAK_EMPTY.0
    } else {
        gas_opt!(ecx, gas::dyn_keccak256_cost(len as u64));
        let offset = try_into_usize!(offset);
        ensure_memory!(ecx, offset, len);
        let data = ecx.memory.slice_len(offset, len);
        primitives::keccak256(&*data).0
    });
    InstructionResult::Continue
}

// Stub implementations for other builtins
// These will need proper implementation when JIT compilation is needed

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_balance(
    _ecx: &mut EvmContext<'_>,
    _address: &mut EvmWord,
    _spec_id: SpecId,
) -> InstructionResult {
    unimplemented!("balance builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_extcodesize(
    _ecx: &mut EvmContext<'_>,
    _address: &mut EvmWord,
    _spec_id: SpecId,
) -> InstructionResult {
    unimplemented!("extcodesize builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_blockhash(
    _ecx: &mut EvmContext<'_>,
    _number: &mut EvmWord,
) -> InstructionResult {
    unimplemented!("blockhash builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_sload(
    _ecx: &mut EvmContext<'_>,
    _index: &mut EvmWord,
    _spec_id: SpecId,
) -> InstructionResult {
    unimplemented!("sload builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_sstore(
    _ecx: &mut EvmContext<'_>,
    _rev: &mut [EvmWord; 2],
    _spec_id: SpecId,
) -> InstructionResult {
    unimplemented!("sstore builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_log(
    _ecx: &mut EvmContext<'_>,
    _rev: &mut [EvmWord; 2],
    _n_topics: u8,
) -> InstructionResult {
    unimplemented!("log builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_selfdestruct(
    _ecx: &mut EvmContext<'_>,
    _address: &mut EvmWord,
    _spec_id: SpecId,
) -> InstructionResult {
    unimplemented!("selfdestruct builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_create(
    _ecx: &mut EvmContext<'_>,
    _rev: &mut [EvmWord; 3],
    _spec_id: SpecId,
) -> InstructionResult {
    unimplemented!("create builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_create2(
    _ecx: &mut EvmContext<'_>,
    _rev: &mut [EvmWord; 4],
    _spec_id: SpecId,
) -> InstructionResult {
    unimplemented!("create2 builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_call(
    _ecx: &mut EvmContext<'_>,
    _rev: &mut [EvmWord; 7],
    _spec_id: SpecId,
) -> InstructionResult {
    unimplemented!("call builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_callcode(
    _ecx: &mut EvmContext<'_>,
    _rev: &mut [EvmWord; 7],
    _spec_id: SpecId,
) -> InstructionResult {
    unimplemented!("callcode builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_delegatecall(
    _ecx: &mut EvmContext<'_>,
    _rev: &mut [EvmWord; 6],
    _spec_id: SpecId,
) -> InstructionResult {
    unimplemented!("delegatecall builtin not yet implemented")
}

#[no_mangle]
pub unsafe extern "C" fn __revmc_builtin_staticcall(
    _ecx: &mut EvmContext<'_>,
    _rev: &mut [EvmWord; 6],
    _spec_id: SpecId,
) -> InstructionResult {
    unimplemented!("staticcall builtin not yet implemented")
}
