use crate::blockchain::Blockchain;
use alloy_rlp::Encodable;
use anyhow::{anyhow, Result};
use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use revm::{
    bytecode::Bytecode,
    context::TxEnv,
    context_interface::result::{ExecutionResult, ResultAndState},
    database_interface::{DBErrorMarker, Database},
    primitives::{keccak256 as rKeccak256, Address as rAddress, TxKind, B256, U256 as rU256},
    state::AccountInfo,
    Context, ExecuteEvm, MainBuilder, MainContext,
};
use std::sync::Arc;
use zephyria_state::trie::VerkleState;
use zephyria_types::{Address, Block, Bytes, Hash, Log, Receipt, Transaction, U256};

#[derive(Debug, thiserror::Error)]
pub enum DatabaseError {
    #[error("Database error: {0}")]
    Message(String),
}

impl DBErrorMarker for DatabaseError {}

pub struct Executor {
    pub blockchain: Arc<Blockchain>,
}

pub struct ZephyriaRevmDb<'a> {
    pub state: &'a mut VerkleState,
}

impl<'a> Database for ZephyriaRevmDb<'a> {
    type Error = DatabaseError;

    fn basic(&mut self, _address: rAddress) -> Result<Option<AccountInfo>, Self::Error> {
        // TODO: Map VerkleState to AccountInfo
        Ok(None)
    }

    fn code_by_hash(&mut self, _code_hash: B256) -> Result<Bytecode, Self::Error> {
        Ok(Bytecode::default())
    }

    fn storage(&mut self, _address: rAddress, _index: rU256) -> Result<rU256, Self::Error> {
        Ok(rU256::ZERO)
    }

    fn block_hash(&mut self, _number: u64) -> Result<B256, Self::Error> {
        Ok(B256::ZERO)
    }
}

impl Executor {
    pub fn new(blockchain: Arc<Blockchain>) -> Self {
        Self { blockchain }
    }

    pub fn apply_block(
        &self,
        block: &Block,
        state: &mut VerkleState,
    ) -> Result<(Vec<Receipt>, Hash)> {
        let mut receipts = Vec::new();
        let mut cumulative_gas = 0;

        for tx in &block.transactions {
            // 1. Recover Sender
            let from = recover_sender(tx)?;

            // 2. Transact
            let mut db = ZephyriaRevmDb { state };

            let mut context = Context::mainnet().with_db(&mut db);

            // Block Env
            context.block.number = rU256::from(block.header.number.to::<u64>());
            context.block.beneficiary = rAddress::from_slice(block.header.coinbase.as_slice());
            context.block.timestamp = rU256::from(block.header.time);
            if let Some(base_fee) = block.header.base_fee {
                context.block.basefee = base_fee.to::<u64>();
            }

            let mut evm = context.build_mainnet();

            let tx_kind = if tx.to == Address::ZERO {
                TxKind::Create
            } else {
                TxKind::Call(rAddress::from_slice(tx.to.as_slice()))
            };

            let tx_env = TxEnv::builder()
                .caller(rAddress::from_slice(from.as_slice()))
                .gas_limit(tx.gas)
                .gas_price(tx.gas_price.to::<u128>())
                .kind(tx_kind)
                .value(rU256::from_be_bytes(tx.value.to_be_bytes::<32>()))
                .data(revm::primitives::Bytes::copy_from_slice(tx.input.as_ref()))
                .nonce(tx.nonce)
                .build()
                .map_err(|e| anyhow!("TxEnv build error: {:?}", e))?;

            let ResultAndState {
                result,
                state: changes,
            } = evm
                .transact(tx_env)
                .map_err(|e| anyhow!("EVM execution error: {:?}", e))?;

            // 3. Commit State Changes
            for (addr, acc) in changes {
                // Update nonce, balance, code if changed
                // This will be implemented in detail once we have the state writer ready
                let _ = addr;
                let _ = acc;
            }

            // 4. Create Receipt
            let gas_used = result.gas_used();
            cumulative_gas += gas_used;
            let success = result.is_success();

            let logs = match result {
                ExecutionResult::Success { logs, .. } => logs
                    .into_iter()
                    .map(|l| Log {
                        address: Address::from_slice(l.address.as_slice()),
                        topics: l
                            .topics()
                            .iter()
                            .map(|t| Hash::from_slice(t.as_slice()))
                            .collect(),
                        data: Bytes::copy_from_slice(l.data.data.as_ref()),
                    })
                    .collect(),
                _ => Vec::new(),
            };

            receipts.push(Receipt {
                status: if success { 1 } else { 0 },
                cumulative_gas_used: cumulative_gas,
                logs_bloom: Default::default(),
                logs,
                tx_hash: tx.hash(),
                gas_used,
                contract_address: None,
            });
        }

        Ok((receipts, state.root()))
    }
}

pub fn recover_sender(tx: &Transaction) -> Result<Address> {
    let mut sig_bytes = [0u8; 65];
    let r_bytes = tx.r.to_be_bytes::<32>();
    let s_bytes = tx.s.to_be_bytes::<32>();
    sig_bytes[..32].copy_from_slice(&r_bytes);
    sig_bytes[32..64].copy_from_slice(&s_bytes);

    let v = tx.v.to::<u64>();
    let recid = if v >= 35 {
        (v - 35) % 2
    } else if v == 27 || v == 28 {
        v - 27
    } else {
        return Err(anyhow!("Invalid v value"));
    };
    sig_bytes[64] = recid as u8;

    let signature =
        Signature::try_from(&sig_bytes[..64]).map_err(|e| anyhow!("Invalid signature: {:?}", e))?;
    let recovery_id =
        RecoveryId::try_from(recid as u8).map_err(|e| anyhow!("Invalid recovery id: {:?}", e))?;

    // Hash of the transaction (excluding signature)
    let mut out = Vec::new();

    // Manual RLP list encoding for recovery hash (EIP-155)
    // [nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]
    let mut rlp = alloy_rlp::Header {
        list: true,
        payload_length: 0,
    };

    let mut payload = Vec::new();
    tx.nonce.encode(&mut payload);
    tx.gas_price.encode(&mut payload);
    tx.gas.encode(&mut payload);
    tx.to.encode(&mut payload);
    tx.value.encode(&mut payload);
    tx.input.encode(&mut payload);
    tx.chain_id.encode(&mut payload);
    0u64.encode(&mut payload);
    0u64.encode(&mut payload);

    rlp.payload_length = payload.len();
    rlp.encode(&mut out);
    out.extend_from_slice(&payload);

    let msg_hash = rKeccak256(&out);

    let vk = VerifyingKey::recover_from_prehash(msg_hash.as_slice(), &signature, recovery_id)
        .map_err(|e| anyhow!("Recovery failed: {:?}", e))?;

    let public_key = vk.to_encoded_point(false);
    let public_key_bytes = public_key.as_bytes();
    // Skip the first byte (0x04)
    let hash = rKeccak256(&public_key_bytes[1..]);
    let mut addr = [0u8; 20];
    addr.copy_from_slice(&hash[12..]);
    Ok(Address::from(addr))
}
