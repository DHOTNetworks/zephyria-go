#![doc = include_str!("../README.md")]
#![cfg_attr(not(test), warn(unused_extern_crates))]
#![cfg_attr(docsrs, feature(doc_cfg, doc_auto_cfg))]
#![cfg_attr(not(feature = "std"), no_std)]

extern crate alloc;

use alloc::vec::Vec;
use core::{fmt, mem::MaybeUninit, ptr};
use interpreter::{
    interpreter_types::{InputsTr, Jumps, LoopControl, ReturnData, RuntimeFlag},
    Gas, Host, InstructionResult, Interpreter, InterpreterAction, InterpreterResult, SharedMemory,
    Stack,
};
use primitives::{Address, Bytes, U256};

#[cfg(feature = "host-ext-any")]
use core::any::Any;

/// The EVM bytecode compiler runtime context.
///
/// This is a simple wrapper around the interpreter's resources, allowing the compiled function to
/// access the memory, contract, gas, host, and other resources.
pub struct EvmContext<'a> {
    /// The memory.
    pub memory: &'a mut SharedMemory,
    /// The gas.
    pub gas: &'a mut Gas,
    /// The host.
    pub host: &'a mut dyn HostExt,
    /// The return data.
    pub return_data: &'a Bytes,
    /// Whether the context is static.
    pub is_static: bool,
    /// Target address for the current execution context.
    pub target_address: Address,
    /// Caller address for the current execution context.
    pub caller_address: Address,
    /// Call value for the current execution context.
    pub call_value: U256,
    /// An index that is used internally to keep track of where execution should resume.
    /// `0` is the initial state.
    #[doc(hidden)]
    pub resume_at: usize,
}

impl fmt::Debug for EvmContext<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EvmContext")
            .field("memory", &self.memory)
            .field("target_address", &self.target_address)
            .field("is_static", &self.is_static)
            .finish_non_exhaustive()
    }
}

impl<'a> EvmContext<'a> {
    /// Creates a new context from an interpreter.
    #[inline]
    pub fn from_interpreter(interpreter: &'a mut Interpreter, host: &'a mut dyn HostExt) -> Self {
        Self::from_interpreter_with_stack(interpreter, host).0
    }

    /// Creates a new context from an interpreter.
    #[inline]
    pub fn from_interpreter_with_stack<'b: 'a>(
        interpreter: &'a mut Interpreter,
        host: &'b mut dyn HostExt,
    ) -> (Self, &'a mut EvmStack, &'a mut usize) {
        let (stack, stack_len) = EvmStack::from_interpreter_stack(&mut interpreter.stack);

        // Get PC from bytecode
        let resume_at = interpreter.bytecode.pc();

        // Get return data as Bytes
        let return_data_bytes = interpreter.return_data.buffer();

        // Get static flag from runtime_flag
        let is_static = interpreter.runtime_flag.is_static();

        // Get input data
        let target_address = interpreter.input.target_address();
        let caller_address = interpreter.input.caller_address();
        let call_value = interpreter.input.call_value();

        let this = Self {
            memory: &mut interpreter.memory,
            gas: &mut interpreter.gas,
            host,
            return_data: return_data_bytes,
            is_static,
            target_address,
            caller_address,
            call_value,
            resume_at,
        };
        (this, stack, stack_len)
    }
}

/// Extension trait for [`Host`].
#[cfg(not(feature = "host-ext-any"))]
pub trait HostExt: Host {}

#[cfg(not(feature = "host-ext-any"))]
impl<T: Host> HostExt for T {}

/// Extension trait for [`Host`].
#[cfg(feature = "host-ext-any")]
pub trait HostExt: Host + Any {
    #[doc(hidden)]
    fn as_any(&self) -> &dyn Any;
    #[doc(hidden)]
    fn as_any_mut(&mut self) -> &mut dyn Any;
}

#[cfg(feature = "host-ext-any")]
impl<T: Host + Any> HostExt for T {
    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}

#[cfg(feature = "host-ext-any")]
#[doc(hidden)]
impl dyn HostExt {
    /// Attempts to downcast the host to a concrete type.
    pub fn downcast_ref<T: Any>(&self) -> Option<&T> {
        self.as_any().downcast_ref()
    }

    /// Attempts to downcast the host to a concrete type.
    pub fn downcast_mut<T: Any>(&mut self) -> Option<&mut T> {
        self.as_any_mut().downcast_mut()
    }
}

/// Declare [`RawEvmCompilerFn`] functions in an `extern \"C\"` block.
///
/// # Examples
///
/// ```no_run
/// use context::{extern_revmc, EvmCompilerFn};
///
/// extern_revmc! {
///    /// A simple function that returns `Continue`.
///    pub fn test_fn;
/// }
///
/// let test_fn = EvmCompilerFn::new(test_fn);
/// ```
#[macro_export]
macro_rules! extern_revmc {
    ($( $(#[$attr:meta])* $vis:vis fn $name:ident; )+) => {
        #[allow(improper_ctypes)]
        extern "C" {
            $(
                $(#[$attr])*
                $vis fn $name(
                    gas: *mut $crate::private::interpreter::Gas,
                    stack: *mut $crate::EvmStack,
                    stack_len: *mut usize,
                    ecx: *mut $crate::EvmContext<'_>,
                ) -> $crate::private::interpreter::InstructionResult;
            )+
        }
    };
}

/// The raw function signature of a bytecode function.
///
/// Prefer using [`EvmCompilerFn`] instead of this type. See [`EvmCompilerFn::call`] for more
/// information.
// When changing the signature, also update the corresponding declarations in `fn translate`.
pub type RawEvmCompilerFn = unsafe extern "C" fn(
    gas: *mut Gas,
    stack: *mut EvmStack,
    stack_len: *mut usize,
    ecx: *mut EvmContext<'_>,
) -> InstructionResult;

/// An EVM bytecode function.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct EvmCompilerFn(RawEvmCompilerFn);

impl From<RawEvmCompilerFn> for EvmCompilerFn {
    #[inline]
    fn from(f: RawEvmCompilerFn) -> Self {
        Self::new(f)
    }
}

impl From<EvmCompilerFn> for RawEvmCompilerFn {
    #[inline]
    fn from(f: EvmCompilerFn) -> Self {
        f.into_inner()
    }
}

impl EvmCompilerFn {
    /// Wraps the function.
    #[inline]
    pub const fn new(f: RawEvmCompilerFn) -> Self {
        Self(f)
    }

    /// Unwraps the function.
    #[inline]
    pub const fn into_inner(self) -> RawEvmCompilerFn {
        self.0
    }

    /// Calls the function by re-using the interpreter's resources and memory.
    ///
    /// See [`call_with_interpreter_and_memory`](Self::call_with_interpreter_and_memory) for more
    /// information.
    ///
    /// # Safety
    ///
    /// The caller must ensure that the function is safe to call.
    #[inline]
    pub unsafe fn call_with_interpreter_and_memory(
        self,
        interpreter: &mut Interpreter,
        memory: &mut SharedMemory,
        host: &mut dyn HostExt,
    ) -> InterpreterAction {
        // Swap memory temporarily
        let old_memory = core::mem::replace(&mut interpreter.memory, memory.clone());
        let result = self.call_with_interpreter(interpreter, host);
        *memory = core::mem::replace(&mut interpreter.memory, old_memory);
        result
    }

    /// Calls the function by re-using the interpreter's resources.
    ///
    /// This behaves the same as [`Interpreter::run`], returning an [`InstructionResult`] and
    /// the next action.
    ///
    /// # Safety
    ///
    /// The caller must ensure that the function is safe to call.
    #[inline]
    pub unsafe fn call_with_interpreter(
        self,
        interpreter: &mut Interpreter,
        host: &mut dyn HostExt,
    ) -> InterpreterAction {
        let (mut ecx, stack, stack_len) =
            EvmContext::from_interpreter_with_stack(interpreter, host);
        let result = self.call(Some(stack), Some(stack_len), &mut ecx);

        // Set the remaining gas to 0 if the result is `OutOfGas`,
        // as it might have overflown inside of the function.
        if result == InstructionResult::OutOfGas {
            ecx.gas.spend_all();
        }

        let resume_at = ecx.resume_at;
        let return_data_empty = ecx.return_data.is_empty();

        // Drop ecx to release borrows
        drop(ecx);

        // Update PC in bytecode
        interpreter.bytecode.absolute_jump(resume_at);

        // Clear return data if empty
        if return_data_empty {
            interpreter.return_data.clear();
        }

        // Check if there's an action set in the bytecode
        let action_opt = interpreter.bytecode.action();
        if let Some(action) = action_opt.take() {
            action
        } else {
            // Return with the result
            InterpreterAction::Return(InterpreterResult {
                result,
                output: Bytes::new(),
                gas: interpreter.gas,
            })
        }
    }

    /// Calls the function.
    ///
    /// Arguments:
    /// - `stack`: Pointer to the stack. Must be `Some` if `local_stack` is set to `false`.
    /// - `stack_len`: Pointer to the stack length. Must be `Some` if `inspect_stack_length` is set
    ///   to `true`.
    /// - `ecx`: The context object.
    ///
    /// These conditions are enforced at runtime if `debug_assertions` is set to `true`.
    ///
    /// Use of this method is discouraged, as setup and cleanup need to be done manually.
    ///
    /// # Safety
    ///
    /// The caller must ensure that the arguments are valid and that the function is safe to call.
    #[inline]
    pub unsafe fn call(
        self,
        stack: Option<&mut EvmStack>,
        stack_len: Option<&mut usize>,
        ecx: &mut EvmContext<'_>,
    ) -> InstructionResult {
        (self.0)(
            ecx.gas,
            option_as_mut_ptr(stack),
            option_as_mut_ptr(stack_len),
            ecx,
        )
    }

    /// Same as [`call`](Self::call) but with `#[inline(never)]`.
    ///
    /// Use of this method is discouraged, as setup and cleanup need to be done manually.
    ///
    /// # Safety
    ///
    /// See [`call`](Self::call).
    #[inline(never)]
    pub unsafe fn call_noinline(
        self,
        stack: Option<&mut EvmStack>,
        stack_len: Option<&mut usize>,
        ecx: &mut EvmContext<'_>,
    ) -> InstructionResult {
        self.call(stack, stack_len, ecx)
    }
}

/// EVM context stack.
#[repr(C)]
#[allow(missing_debug_implementations)]
pub struct EvmStack([MaybeUninit<EvmWord>; 1024]);

#[allow(clippy::new_without_default)]
impl EvmStack {
    /// The size of the stack in bytes.
    pub const SIZE: usize = 32 * Self::CAPACITY;

    /// The size of the stack in U256 elements.
    pub const CAPACITY: usize = 1024;

    /// Creates a new EVM stack, allocated on the stack.
    ///
    /// Use [`EvmStack::new_heap`] to create a stack on the heap.
    #[inline]
    pub fn new() -> Self {
        Self(unsafe { MaybeUninit::uninit().assume_init() })
    }

    /// Creates a vector that can be used as a stack.
    #[inline]
    pub fn new_heap() -> Vec<EvmWord> {
        Vec::with_capacity(1024)
    }

    /// Creates a stack from the interpreter's stack. Assumes that the stack is large enough.
    #[inline]
    pub fn from_interpreter_stack(stack: &mut Stack) -> (&mut Self, &mut usize) {
        debug_assert!(stack.data().capacity() >= Self::CAPACITY);
        unsafe {
            let data = Self::from_mut_ptr(stack.data_mut().as_mut_ptr().cast());
            // Vec { data: ptr, cap: usize, len: usize }
            let len = &mut *(stack.data_mut() as *mut Vec<_>).cast::<usize>().add(2);
            debug_assert_eq!(stack.len(), *len);
            (data, len)
        }
    }

    /// Creates a stack from a vector's buffer.
    ///
    /// # Panics
    ///
    /// Panics if the vector's capacity is less than the required stack capacity.
    #[inline]
    pub fn from_vec(vec: &Vec<EvmWord>) -> &Self {
        assert!(vec.capacity() >= Self::CAPACITY);
        unsafe { Self::from_ptr(vec.as_ptr()) }
    }

    /// Creates a stack from a mutable vector's buffer.
    ///
    /// The bytecode function will overwrite the internal contents of the vector, and will not
    /// set the length. This is simply to have the stack allocated on the heap.
    ///
    /// # Panics
    ///
    /// Panics if the vector's capacity is less than the required stack capacity.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use context::EvmStack;
    /// let mut stack_buf = EvmStack::new_heap();
    /// let stack = EvmStack::from_mut_vec(&mut stack_buf);
    /// assert_eq!(stack.as_slice().len(), EvmStack::CAPACITY);
    /// ```
    #[inline]
    pub fn from_mut_vec(vec: &mut Vec<EvmWord>) -> &mut Self {
        assert!(vec.capacity() >= Self::CAPACITY);
        unsafe { Self::from_mut_ptr(vec.as_mut_ptr()) }
    }

    /// Creates a stack from a slice.
    ///
    /// # Panics
    ///
    /// Panics if the slice's length is less than the required stack capacity.
    #[inline]
    pub const fn from_slice(slice: &[EvmWord]) -> &Self {
        assert!(slice.len() >= Self::CAPACITY);
        unsafe { Self::from_ptr(slice.as_ptr()) }
    }

    /// Creates a stack from a mutable slice.
    ///
    /// # Panics
    ///
    /// Panics if the slice's length is less than the required stack capacity.
    #[inline]
    pub fn from_mut_slice(slice: &mut [EvmWord]) -> &mut Self {
        assert!(slice.len() >= Self::CAPACITY);
        unsafe { Self::from_mut_ptr(slice.as_mut_ptr()) }
    }

    /// Creates a stack from a pointer.
    ///
    /// # Safety
    ///
    /// The caller must ensure that the pointer is valid and points to at least [`EvmStack::SIZE`]
    /// bytes.
    #[inline]
    pub const unsafe fn from_ptr<'a>(ptr: *const EvmWord) -> &'a Self {
        &*ptr.cast()
    }

    /// Creates a stack from a mutable pointer.
    ///
    /// # Safety
    ///
    /// The caller must ensure that the pointer is valid and points to at least [`EvmStack::SIZE`]
    /// bytes.
    #[inline]
    pub unsafe fn from_mut_ptr<'a>(ptr: *mut EvmWord) -> &'a mut Self {
        &mut *ptr.cast()
    }

    /// Returns the stack as a byte array.
    #[inline]
    pub const fn as_bytes(&self) -> &[u8; Self::SIZE] {
        unsafe { &*self.0.as_ptr().cast() }
    }

    /// Returns the stack as a byte array.
    #[inline]
    pub fn as_bytes_mut(&mut self) -> &mut [u8; Self::SIZE] {
        unsafe { &mut *self.0.as_mut_ptr().cast() }
    }

    /// Returns the stack as a slice.
    #[inline]
    pub const fn as_slice(&self) -> &[EvmWord; Self::CAPACITY] {
        unsafe { &*self.0.as_ptr().cast() }
    }

    /// Returns the stack as a mutable slice.
    #[inline]
    pub fn as_mut_slice(&mut self) -> &mut [EvmWord; Self::CAPACITY] {
        unsafe { &mut *self.0.as_mut_ptr().cast() }
    }
}

/// A native-endian 256-bit unsigned integer, aligned to 8 bytes.
///
/// This is a transparent wrapper around [`U256`] on little-endian targets.
#[repr(C, align(8))]
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct EvmWord([u8; 32]);

macro_rules! impl_fmt {
    ($($trait:ident),* $(,)?) => {
        $(
            impl fmt::$trait for EvmWord {
                #[inline]
                fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                    self.to_u256().fmt(f)
                }
            }
        )*
    };
}

impl_fmt!(Debug, Display, Binary, Octal, LowerHex, UpperHex);

macro_rules! impl_conversions_through_u256 {
    ($($ty:ty),*) => {
        $(
            impl From<$ty> for EvmWord {
                #[inline]
                fn from(value: $ty) -> Self {
                    Self::from_u256(U256::from(value))
                }
            }

            impl From<&$ty> for EvmWord {
                #[inline]
                fn from(value: &$ty) -> Self {
                    Self::from(*value)
                }
            }

            impl From<&mut $ty> for EvmWord {
                #[inline]
                fn from(value: &mut $ty) -> Self {
                    Self::from(*value)
                }
            }

            impl TryFrom<EvmWord> for $ty {
                type Error = ();

                #[inline]
                fn try_from(value: EvmWord) -> Result<Self, Self::Error> {
                    value.to_u256().try_into().map_err(drop)
                }
            }

            impl TryFrom<&EvmWord> for $ty {
                type Error = ();

                #[inline]
                fn try_from(value: &EvmWord) -> Result<Self, Self::Error> {
                    (*value).try_into()
                }
            }

            impl TryFrom<&mut EvmWord> for $ty {
                type Error = ();

                #[inline]
                fn try_from(value: &mut EvmWord) -> Result<Self, Self::Error> {
                    (*value).try_into()
                }
            }
        )*
    };
}

impl_conversions_through_u256!(bool, u8, u16, u32, u64, usize, u128);

impl From<U256> for EvmWord {
    #[inline]
    fn from(value: U256) -> Self {
        Self::from_u256(value)
    }
}

impl From<&U256> for EvmWord {
    #[inline]
    fn from(value: &U256) -> Self {
        Self::from(*value)
    }
}

impl From<&mut U256> for EvmWord {
    #[inline]
    fn from(value: &mut U256) -> Self {
        Self::from(*value)
    }
}

impl EvmWord {
    /// The zero value.
    pub const ZERO: Self = Self([0; 32]);

    /// Creates a new value from native-endian bytes.
    #[inline]
    pub const fn from_ne_bytes(x: [u8; 32]) -> Self {
        Self(x)
    }

    /// Creates a new value from big-endian bytes.
    #[inline]
    pub fn from_be_bytes(x: [u8; 32]) -> Self {
        Self::from_be(Self(x))
    }

    /// Creates a new value from little-endian bytes.
    #[inline]
    pub fn from_le_bytes(x: [u8; 32]) -> Self {
        Self::from_le(Self(x))
    }

    /// Converts an integer from big endian to the target's endianness.
    #[inline]
    pub fn from_be(x: Self) -> Self {
        #[cfg(target_endian = "little")]
        return x.swap_bytes();
        #[cfg(target_endian = "big")]
        return x;
    }

    /// Converts an integer from little endian to the target's endianness.
    #[inline]
    pub fn from_le(x: Self) -> Self {
        #[cfg(target_endian = "little")]
        return x;
        #[cfg(target_endian = "big")]
        return x.swap_bytes();
    }

    /// Converts a [`U256`].
    #[inline]
    pub const fn from_u256(value: U256) -> Self {
        #[cfg(target_endian = "little")]
        return unsafe { core::mem::transmute::<U256, Self>(value) };
        #[cfg(target_endian = "big")]
        return Self(value.to_be_bytes());
    }

    /// Converts a [`U256`] reference to a [`U256`].
    #[inline]
    #[cfg(target_endian = "little")]
    pub const fn from_u256_ref(value: &U256) -> &Self {
        unsafe { &*(value as *const U256 as *const Self) }
    }

    /// Converts a [`U256`] mutable reference to a [`U256`].
    #[inline]
    #[cfg(target_endian = "little")]
    pub fn from_u256_mut(value: &mut U256) -> &mut Self {
        unsafe { &mut *(value as *mut U256 as *mut Self) }
    }

    /// Return the memory representation of this integer as a byte array in big-endian (network)
    /// byte order.
    #[inline]
    pub fn to_be_bytes(self) -> [u8; 32] {
        self.to_be().to_ne_bytes()
    }

    /// Return the memory representation of this integer as a byte array in little-endian byte
    /// order.
    #[inline]
    pub fn to_le_bytes(self) -> [u8; 32] {
        self.to_le().to_ne_bytes()
    }

    /// Return the memory representation of this integer as a byte array in native byte order.
    #[inline]
    pub const fn to_ne_bytes(self) -> [u8; 32] {
        self.0
    }

    /// Converts `self` to big endian from the target's endianness.
    #[inline]
    pub fn to_be(self) -> Self {
        #[cfg(target_endian = "little")]
        return self.swap_bytes();
        #[cfg(target_endian = "big")]
        return self;
    }

    /// Converts `self` to little endian from the target's endianness.
    #[inline]
    pub fn to_le(self) -> Self {
        #[cfg(target_endian = "little")]
        return self;
        #[cfg(target_endian = "big")]
        return self.swap_bytes();
    }

    /// Reverses the byte order of the integer.
    #[inline]
    pub fn swap_bytes(mut self) -> Self {
        self.0.reverse();
        self
    }

    /// Casts this value to a [`U256`]. This is a no-op on little-endian systems.
    #[cfg(target_endian = "little")]
    #[inline]
    pub const fn as_u256(&self) -> &U256 {
        unsafe { &*(self as *const Self as *const U256) }
    }

    /// Casts this value to a [`U256`]. This is a no-op on little-endian systems.
    #[cfg(target_endian = "little")]
    #[inline]
    pub fn as_u256_mut(&mut self) -> &mut U256 {
        unsafe { &mut *(self as *mut Self as *mut U256) }
    }

    /// Converts this value to a [`U256`]. This is a simple copy on little-endian systems.
    #[inline]
    pub const fn to_u256(&self) -> U256 {
        #[cfg(target_endian = "little")]
        return *self.as_u256();
        #[cfg(target_endian = "big")]
        return U256::from_be_bytes(self.0);
    }

    /// Converts this value to a [`U256`]. This is a no-op on little-endian systems.
    #[inline]
    pub const fn into_u256(self) -> U256 {
        #[cfg(target_endian = "little")]
        return unsafe { core::mem::transmute::<Self, U256>(self) };
        #[cfg(target_endian = "big")]
        return U256::from_be_bytes(self.0);
    }

    /// Converts this value to an [`Address`].
    #[inline]
    pub fn to_address(self) -> Address {
        Address::from_word(self.to_be_bytes().into())
    }
}

#[inline(always)]
fn option_as_mut_ptr<T>(opt: Option<&mut T>) -> *mut T {
    match opt {
        Some(ref_) => ref_,
        None => ptr::null_mut(),
    }
}

// Macro re-exports.
// Not public API.
#[doc(hidden)]
pub mod private {
    pub use interpreter;
    pub use primitives;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversions() {
        let mut word = EvmWord::ZERO;
        assert_eq!(usize::try_from(word), Ok(0));
        assert_eq!(usize::try_from(&word), Ok(0));
        assert_eq!(usize::try_from(&mut word), Ok(0));
    }

    extern_revmc! {
        #[link_name = "__test_fn"]
        fn test_fn;
    }

    #[no_mangle]
    extern "C" fn __test_fn(
        _gas: *mut Gas,
        _stack: *mut EvmStack,
        _stack_len: *mut usize,
        _ecx: *mut EvmContext<'_>,
    ) -> InstructionResult {
        InstructionResult::Continue
    }

    #[test]
    fn test_fn_call() {
        let f = EvmCompilerFn::new(__test_fn);
        assert_eq!(f.into_inner(), __test_fn);
    }
}
