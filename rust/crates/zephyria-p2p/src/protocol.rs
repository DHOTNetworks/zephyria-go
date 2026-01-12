use serde::{Deserialize, Serialize};
use zephyria_types::{Hash, Block};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockRequest {
    pub start_hash: Hash,
    pub limit: u64,
    pub reverse: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockResponse {
    pub blocks: Vec<Block>,
}
