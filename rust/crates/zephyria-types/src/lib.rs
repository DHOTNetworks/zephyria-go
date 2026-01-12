pub use alloy_primitives::{keccak256, Address, Bloom, Bytes, B256, U256};
use alloy_rlp::{Encodable, RlpDecodable, RlpEncodable};
use serde::{Deserialize, Serialize};

pub type Hash = B256;
pub type BlockNumber = u64;

#[derive(Debug, Clone, PartialEq, Eq, RlpEncodable, RlpDecodable, Serialize, Deserialize)]
#[rlp(trailing)]
pub struct Header {
    pub parent_hash: Hash,
    pub uncle_hash: Hash, // Kept for compatibility if needed, or zero
    pub coinbase: Address,
    pub state_root: Hash,
    pub tx_hash: Hash,
    pub receipt_hash: Hash,
    pub bloom: Bloom,
    pub difficulty: U256,
    pub number: U256,
    pub gas_limit: u64,
    pub gas_used: u64,
    pub time: u64,
    pub extra_data: Bytes,
    pub mix_digest: Hash,
    pub nonce: u64,
    pub base_fee: Option<U256>,
}

impl Header {
    pub fn hash(&self) -> Hash {
        let mut out = Vec::new();
        self.encode(&mut out);
        keccak256(&out)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, RlpEncodable, RlpDecodable, Serialize, Deserialize)]
pub struct Transaction {
    pub chain_id: u64,
    pub nonce: u64,
    pub gas_price: U256,
    pub gas: u64,
    pub to: Address, // If empty/zero -> Create
    pub value: U256,
    pub input: Bytes,
    pub v: U256,
    pub r: U256,
    pub s: U256,
}

impl Transaction {
    pub fn hash(&self) -> Hash {
        let mut out = Vec::new();
        self.encode(&mut out);
        keccak256(&out)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, RlpEncodable, RlpDecodable, Serialize, Deserialize)]
pub struct Log {
    pub address: Address,
    pub topics: Vec<Hash>,
    pub data: Bytes,
}

#[derive(Debug, Clone, PartialEq, Eq, RlpEncodable, RlpDecodable, Serialize, Deserialize)]
#[rlp(trailing)]
pub struct Receipt {
    pub status: u64, // 1 success, 0 failure
    pub cumulative_gas_used: u64,
    pub logs_bloom: Bloom,
    pub logs: Vec<Log>,
    #[rlp(skip)]
    pub tx_hash: Hash, // Computed/Stored separately often
    #[rlp(skip)]
    pub gas_used: u64, // Stored separately often
    pub contract_address: Option<Address>, // Derived if tx was create
}

#[derive(Debug, Clone, PartialEq, Eq, RlpEncodable, RlpDecodable, Serialize, Deserialize)]
pub struct Block {
    pub header: Header,
    pub transactions: Vec<Transaction>,
    pub uncles: Vec<Header>,
}

impl Block {
    pub fn hash(&self) -> Hash {
        self.header.hash()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, RlpEncodable, RlpDecodable, Serialize, Deserialize)]
pub struct Validator {
    pub address: Address,
    pub stake: U256,
    pub bls_pub_key: Bytes, // 48 bytes compressed G1
}

#[derive(Debug, Clone, PartialEq, Eq, RlpEncodable, RlpDecodable, Serialize, Deserialize)]
pub struct Vote {
    pub block_hash: Hash,
    pub validator_index: u64,
    pub view: u64,
    pub signature: Bytes, // 96 bytes compressed G2
}
