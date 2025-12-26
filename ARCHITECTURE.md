# Zephyria System Architecture

This document outlines the core components of the Zephyria blockchain engine and their specific responsibilities.

## 1. Node Service (`node/`)
**File**: `node/node.go`
- **Role**: The "Motherboard" or Central Orchestrator.
- **Function**:
  - Initializes all other subsystems (DB, State, Consensus, P2P).
  - Runs the main **Event Loop**:
    - Receives incoming blocks from P2P.
    - Intercepts **Staking Transactions**.
    - Triggers **Consensus Rounds** to mine new blocks.
    - Coordinates **Parallel Execution** of transactions.
    - Commits state changes to the Database.
  - Logs high-level Metrics (TPS, Block Time, Finality).

## 2. Core Logic (`core/`)
**Files**: `core/blockchain.go`, `core/executor.go`, `core/rawdb/`
- **Role**: The "Engine Room".
- **Function**:
  - **Blockchain**: Manages the canonical history of blocks. Indexes BlockHash -> BlockNumber.
  - **Executor**: The State Transition Machine.
    - **Sealevel**: Executes transactions in parallel (simulated concurrency).
    - Applies balance transfers and state updates to the `StateDB`.
  - **RawDB**: Low-level database accessors for storing Blocks and Canonical Indices in LevelDB.

## 3. Consensus Engine (`consensus/`)
**File**: `consensus/hbbft.go`
- **Role**: The "Brain" (Security & Agreement).
- **Algorithm**: **HBBFT-Lite (HoneyBadger BFT with Dynamic PoS)**.
- **Function**:
  - **Dynamic Staking**: Manages an open Validator Set (`AddValidator`, `RemoveValidator`, `Slash`).
  - **Proposal Selection**: Uses **Weighted Randomness** (seeded by previous block hash) to select block proposers fairly based on stake.
  - **Cryptographic Sealing**: Signs block headers with the Validator's **ECDSA Private Key** (`Seal`).
  - **Verification**: Validates signatures on incoming blocks (`Verify`) to prevent unauthorized mining.

## 4. State Management (`state/`)
**File**: `state/statedb.go`
- **Role**: The "Memory".
- **Function**:
  - **Verkle Trie**: efficient, stateless-friendly storage structure for Account Balances.
  - **StateDB**: logical overlay on top of the Trie. Handles `GetBalance`, `SetBalance`.
  - **Persistence**: Implements `Commit()` to flush in-memory changes to the LevelDB disk storage.

## 5. Networking (`p2p/`)
**Files**: `p2p/server.go`, `p2p/peer.go`, `p2p/message.go`
- **Role**: The "Nervous System".
- **Function**:
  - **Server**: Listens on TCP (default `:30303`). Manages peer lifecycle.
  - **Protocol**: Custom **RLP-encoded** wire protocol.
    - `MsgStatus`: Handshake (Chain Head exchange).
    - `MsgNewBlock`: Broadcasting mined blocks to peers.
    - `MsgGetBlocks` / `MsgBlocks`: Sync protocol to catch up missing history.

## 6. Access Interface (`rpc/`)
**File**: `rpc/api.go`
- **Role**: The "Gateway".
- **Function**:
  - Exposes standard JSON-RPC endpoints (e.g., `eth_blockNumber`, `eth_getBalance`) for external tools, wallets, and benchmarks.
  - Queries `StateDB` and `Blockchain` to return data to users.

## 7. Entrypoint (`main.go`)
- **Role**: The "Ignition".
- **Function**:
  - Parses Command Line Flags (`--port`, `--datadir`, `--bootnodes`).
  - Reads Configuration.
  - Instantiates the `Node` and starts the engine.

## Data Flow Summary
1. **Tx** arrives (via RPC or P2P).
2. **Node** adds it to the batch.
3. **Consensus** selects a Proposer.
4. **HBBFT Engine** creates a block and **Seals** (Signs) it.
5. **Executor** runs the block, updating the **State**.
6. **StateDB** commits changes to LevelDB.
7. **P2P** broadcasts the Signed Block to the network.
