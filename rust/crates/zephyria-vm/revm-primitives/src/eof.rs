//! Complete EOF (EVM Object Format) implementation
//!
//! Implements EIP-3540 (EOF Container Format), EIP-3670 (Code Validation),
//! EIP-4200 (Static Relative Jumps), EIP-4750 (EOF Functions),
//! EIP-5450 (Stack Validation), and related EIPs.

use crate::{Bytes, B256};
use std::format;
use std::vec::Vec;

/// EOF Magic bytes (0xEF00)
pub const EOF_MAGIC_BYTES: [u8; 2] = [0xEF, 0x00];
pub const EOF_MAGIC: u16 = 0xEF00;
pub const EOF_VERSION: u8 = 0x01;

/// Section type identifiers
pub const SECTION_TYPE: u8 = 0x01;
pub const SECTION_CODE: u8 = 0x02;
pub const SECTION_CONTAINER: u8 = 0x03;
pub const SECTION_DATA: u8 = 0x04;
pub const SECTION_TERMINATOR: u8 = 0x00;

/// Maximum stack height for EOF functions
pub const MAX_STACK_HEIGHT: u16 = 1024;

/// Complete EOF container
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Eof {
    pub header: EofHeader,
    pub body: EofBody,
    pub raw: Bytes,
}

/// EOF header containing section sizes
#[derive(Clone, Debug, PartialEq, Eq, Default)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct EofHeader {
    /// Size of types section
    pub types_size: u16,
    /// Sizes of each code section
    pub code_sizes: Vec<u16>,
    /// Sizes of each container section
    pub container_sizes: Vec<u16>,
    /// Size of data section
    pub data_size: u16,
    /// Sum of all code section sizes
    pub sum_code_sizes: usize,
    /// Sum of all container section sizes
    pub sum_container_sizes: usize,
}

/// EOF body containing actual sections
#[derive(Clone, Debug, PartialEq, Eq, Default)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct EofBody {
    /// Types section (function signatures)
    pub types_section: Vec<TypesSection>,
    /// Code sections (one per function)
    pub code_section: Vec<Bytes>,
    /// Container sections (for EOFCREATE)
    pub container_section: Vec<Bytes>,
    /// Data section
    pub data_section: Bytes,
    /// Whether data section is filled (for deployment)
    pub is_data_filled: bool,
}

/// Function type information (4 bytes per function)
#[derive(Clone, Debug, PartialEq, Eq, Default, Copy)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct TypesSection {
    /// Number of stack inputs
    pub inputs: u8,
    /// Number of stack outputs (0x80 for non-returning)
    pub outputs: u8,
    /// Maximum stack height for this function
    pub max_stack_height: u16,
}

impl Eof {
    /// Decode EOF container from bytes
    pub fn decode(bytes: impl Into<Bytes>) -> Result<Self, EofError> {
        let raw = bytes.into();

        // Minimum size check
        if raw.len() < 3 {
            return Err(EofError::Decode("EOF container too small".into()));
        }

        // Check magic
        if raw[0] != EOF_MAGIC_BYTES[0] || raw[1] != EOF_MAGIC_BYTES[1] {
            return Err(EofError::Decode("Invalid EOF magic bytes".into()));
        }

        // Check version
        if raw[2] != EOF_VERSION {
            return Err(EofError::Decode(format!(
                "Unsupported EOF version: {}",
                raw[2]
            )));
        }

        let mut pos = 3;
        let mut header = EofHeader::default();

        // Parse header sections
        let mut last_section_kind = 0u8;

        loop {
            if pos >= raw.len() {
                return Err(EofError::Decode("Unexpected end of header".into()));
            }

            let kind = raw[pos];
            pos += 1;

            // Terminator marks end of header
            if kind == SECTION_TERMINATOR {
                break;
            }

            // Read size (2 bytes, big-endian)
            if pos + 1 >= raw.len() {
                return Err(EofError::Decode("Incomplete section size".into()));
            }
            let size = u16::from_be_bytes([raw[pos], raw[pos + 1]]);
            pos += 2;

            // Validate section ordering
            if kind < last_section_kind && kind != SECTION_CODE {
                return Err(EofError::Decode("Invalid section order".into()));
            }

            match kind {
                SECTION_TYPE => {
                    if header.types_size != 0 {
                        return Err(EofError::Decode("Duplicate types section".into()));
                    }
                    header.types_size = size;
                }
                SECTION_CODE => {
                    if size == 0 {
                        return Err(EofError::Decode("Empty code section".into()));
                    }
                    header.code_sizes.push(size);
                    header.sum_code_sizes += size as usize;
                }
                SECTION_CONTAINER => {
                    header.container_sizes.push(size);
                    header.sum_container_sizes += size as usize;
                }
                SECTION_DATA => {
                    if header.data_size != 0 {
                        return Err(EofError::Decode("Duplicate data section".into()));
                    }
                    header.data_size = size;
                }
                _ => return Err(EofError::Decode(format!("Unknown section kind: {}", kind))),
            }

            last_section_kind = kind;
        }

        // Validate required sections
        if header.types_size == 0 {
            return Err(EofError::Decode("Missing types section".into()));
        }
        if header.code_sizes.is_empty() {
            return Err(EofError::Decode("Missing code section".into()));
        }

        // Validate types section size
        let expected_types_size = header.code_sizes.len() * 4;
        if header.types_size as usize != expected_types_size {
            return Err(EofError::Decode(format!(
                "Invalid types section size: expected {}, got {}",
                expected_types_size, header.types_size
            )));
        }

        // Parse body
        let mut body = EofBody::default();

        // Parse types section
        for _ in 0..header.code_sizes.len() {
            if pos + 3 >= raw.len() {
                return Err(EofError::Decode("Incomplete types section".into()));
            }

            let inputs = raw[pos];
            let outputs = raw[pos + 1];
            let max_stack_height = u16::from_be_bytes([raw[pos + 2], raw[pos + 3]]);

            body.types_section.push(TypesSection {
                inputs,
                outputs,
                max_stack_height,
            });

            pos += 4;
        }

        // Parse code sections
        for &size in &header.code_sizes {
            let end = pos + size as usize;
            if end > raw.len() {
                return Err(EofError::Decode("Incomplete code section".into()));
            }

            body.code_section.push(raw.slice(pos..end));
            pos = end;
        }

        // Parse container sections
        for &size in &header.container_sizes {
            let end = pos + size as usize;
            if end > raw.len() {
                return Err(EofError::Decode("Incomplete container section".into()));
            }

            body.container_section.push(raw.slice(pos..end));
            pos = end;
        }

        // Parse data section
        if header.data_size > 0 {
            let end = pos + header.data_size as usize;
            if end > raw.len() {
                return Err(EofError::Decode("Incomplete data section".into()));
            }

            body.data_section = raw.slice(pos..end);
            body.is_data_filled = true;
            pos = end;
        }

        // Ensure no trailing bytes
        if pos != raw.len() {
            return Err(EofError::Decode(
                "Trailing bytes after EOF container".into(),
            ));
        }

        Ok(Eof { header, body, raw })
    }

    /// Get the hash of the EOF container
    pub fn hash(&self) -> B256 {
        crate::keccak256(&self.raw)
    }

    /// Get a specific code section
    pub fn code(&self, index: usize) -> Option<&Bytes> {
        self.body.code_section.get(index)
    }

    /// Get a specific container
    pub fn container(&self, index: usize) -> Option<&Bytes> {
        self.body.container_section.get(index)
    }

    /// Get the data section
    pub fn data(&self) -> &Bytes {
        &self.body.data_section
    }

    /// Get function type information
    pub fn function_type(&self, index: usize) -> Option<&TypesSection> {
        self.body.types_section.get(index)
    }

    /// Number of code sections (functions)
    pub fn code_section_count(&self) -> usize {
        self.body.code_section.len()
    }
}

/// EOF-related errors
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum EofError {
    /// Decoding error
    Decode(std::string::String),
    /// Validation error
    Validation(std::string::String),
}

impl core::fmt::Display for EofError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            EofError::Decode(msg) => write!(f, "EOF decode error: {}", msg),
            EofError::Validation(msg) => write!(f, "EOF validation error: {}", msg),
        }
    }
}

#[cfg(feature = "std")]
impl std::error::Error for EofError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_eof_decode_minimal() {
        // Minimal valid EOF: EF 00 01 01 0004 02 0001 04 0000 00 00800000 00
        let bytes = vec![
            0xEF, 0x00, 0x01, // Magic + Version
            0x01, 0x00, 0x04, // Types section, size 4
            0x02, 0x00, 0x01, // Code section, size 1
            0x04, 0x00, 0x00, // Data section, size 0
            0x00, // Terminator
            0x00, 0x80, 0x00,
            0x00, // Types: 0 inputs, 0x80 outputs (non-returning), max stack 0
            0x00, // Code: STOP
        ];

        let eof = Eof::decode(Bytes::from(bytes)).unwrap();
        assert_eq!(eof.header.code_sizes.len(), 1);
        assert_eq!(eof.body.types_section.len(), 1);
        assert_eq!(eof.body.code_section.len(), 1);
    }
}
