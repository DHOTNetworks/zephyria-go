# Zephyria Blockchain Specifications

## 1. Overview
Zephyria is a high-performance, EVM-compatible blockchain designed for low latency and high throughput. It utilizes a custom consensus engine named **Zelius**, inspired by Solana's Leader Schedule and TON's robustness.

## 2. Core Features

### Consensus: Zelius (Proof-of-Stake)
-   **Engine**: Zelius Consensus (Deterministic Leader Schedule).
-   **Leader Schedule**: Deterministically calculated per epoch based on Stake Weight, ensuring highly predictable and pipeline-able block production.
-   **Epochs**: Time is divided into epochs (currently dynamic/short for Devnet) where the validator schedule is fixed.
-   **Slashing**: Automated slashing for double-signing and prolonged non-compliance.
-   **Finality**: Instant (blocks are sealed and finalized upon mining by the designated leader).
-   **Pipelining**: Block execution, sealing, and state commitment occur asynchronously to maximize throughput.

### State & Execution
-   **State Model**: Account-based, compatible with Ethereum State Trie (Verkle support experimental).
-   **Executor**: Custom `Executor` implementation supporting parallel signature verification.
-   **Database**: LevelDB for persistence.
-   **Pre-fetching**: Predictive state loading to minimize I/O latency during block execution.

### Economic Model (Proof-of-Stake)
-   **Token**: ZEE (18 decimals).
-   **Validator Set**: Dynamic, managed via on-chain staking transactions.
-   **Staking**: Users can stake ZEE to become validators by sending value to the `StakingAddr`.
-   **Unstaking**: Validators can exit by sending a specific payload ("UNSTAKE") to the `StakingAddr`.

### Networking (Zelius Shield)
-   **Stake-Gated Access**: Permissionless but prioritized entry. Peers must perform a cryptographic handshake to prove they are validators (have staked ZEE).
-   **Priority Access**: Verified validators bypass standard rate limits.
-   **Rate Limiting**: Unknown/Unstaked peers are strictly rate-limited (100 msgs/s) to prevent spam while maintaining openness.
-   **Oversized Protection**: 10MB hard limit on P2P messages to prevent memory exhaustion attacks.

## 3. Interfaces

### RPC (JSON-RPC 2.0)
Zephyria implements a subset of the Ethereum JSON-RPC API, compatible with standard tools (Metamask, web3.js).

| Method | Status | Description |
| :--- | :--- | :--- |
| `eth_blockNumber` | ✅ | Returns current block height. |
| `eth_getBalance` | ✅ | Returns account balance. |
| `eth_getTransactionCount` | ✅ | Returns account nonce. |
| `eth_sendRawTransaction` | ✅ | Submits signed transactions. |
| `eth_getBlockByNumber` | ✅ | Returns block details. |
| `eth_getTransactionByHash` | ✅ | Returns tx details. |
| `eth_getTransactionReceipt` | ✅ | Returns execution receipt. |

### P2P Networking
-   **Discovery**: Bootnode-based peer discovery.
-   **Transport**: TCP.
-   **Protocol**: Custom binary protocol for block propagation.

## 4. Performance Statistics

Based on internal benchmarking (Devnet Mode, Single Node):

-   **Throughput**: ~3,000 - 5,000 TPS (Transactions Per Second).
    -   *Observed*: >1000 txs per ~200ms block.
-   **Latency**: < 500ms (Time to Finality).
-   **Block Processing Time**: ~30ms - 50ms for 1000 simple transfers.
-   **Startup Time**: < 2 seconds.

## 5. System Parameters (Devnet)

-   **Chain ID**: 1337
-   **Gas Limit**: 60,000,000
-   **Base Fee**: 100 wei
-   **P2P Port**: 30303
-   **RPC Port**: 8545

> [!NOTE]
> Performance metrics were gathered using `cmd/bench` flood testing on a local machine. Real-world network latency will inherently reduce global throughput.
