use primitives::{Address, Bytes, Eof, U256};

/// Inputs for an EOF crate
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct EOFCreateInputs {
    pub caller: Address,
    pub created_address: Address,
    pub value: U256,
    pub eof: Eof,
    pub gas_limit: u64,
    pub input: Bytes,
}

impl EOFCreateInputs {
    pub fn new_opcode(
        caller: Address,
        created_address: Address,
        value: U256,
        eof: Eof,
        gas_limit: u64,
        input: Bytes,
    ) -> Self {
        Self {
            caller,
            created_address,
            value,
            eof,
            gas_limit,
            input,
        }
    }
}
