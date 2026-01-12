# Zephyria Blockchain - Production Hardening & Critical Security Fixes

## Design Document for Senior Go Development Team

**Project**: Zephyria Layer-1 Blockchain  
**Design Version**: 1.0  
**Target Go Version**: 1.21+  
**Design Date**: January 2025  
**Design Priority**: CRITICAL - Production Readiness

---

## Executive Summary

This design document outlines the production-ready implementation plan for addressing critical security vulnerabilities and implementation gaps in the Zephyria blockchain. The system currently operates as a proof-of-concept with significant security flaws that prevent mainnet deployment.

**Current State**: Development/PoC Phase with HIGH security risk  
**Target State**: Production-ready blockchain with enterprise-grade security  
**Implementation Scope**: 8 phases over 16-20 weeks  
**Team Composition**: Senior Go developers experienced in distributed systems, cryptography, and blockchain consensus

---

## Design Philosophy & Implementation Standards

### Core Principles

1. **Production-First Mindset**: Every implementation must be production-ready, not a proof-of-concept
2. **Security by Design**: Security considerations precede performance optimizations
3. **Byzantine Fault Tolerance**: Assume adversarial network conditions
4. **Zero Trust Architecture**: Validate all inputs, authenticate all actors, verify all claims
5. **Operational Excellence**: Include comprehensive logging, metrics, and observability

### Code Quality Requirements

- Unit test coverage: Minimum 85% for consensus and state management
- Integration tests: All multi-node scenarios must be covered
- Stress tests: Must sustain 10,000+ TPS for continuous 1-hour periods
- Error handling: All error paths must be explicitly handled
- Logging: Structured logging with appropriate severity levels
- Documentation: Godoc comments for all exported functions and types

---

## Phase 1: Critical Security Vulnerabilities (Weeks 1-2)

**Priority**: 🔥 IMMEDIATE - BLOCKS MAINNET DEPLOYMENT  
**Risk Level**: CRITICAL  
**Estimated Effort**: 40-60 hours

### 1.1 Secure Key Management System

**Problem**: Hardcoded private keys in `core/genesis.go:26` and `cmd/zephyria/main.go:60` expose the network to catastrophic compromise.

**Current Vulnerable State**:
```
DefaultDevKey = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
```

**Design Solution**:

#### Key Management Architecture

The system will implement a multi-tiered key management approach based on network type:

**Network-Specific Key Policies**:
- **Mainnet/Testnet**: Mandatory external key source, no defaults permitted
- **Devnet**: Hardcoded keys permitted with prominent warnings
- **Simulation**: Deterministic keys allowed for reproducible testing

**Key Source Hierarchy** (Priority Order):
1. Environment variable: `ZEPHYRIA_VALIDATOR_KEY`
2. Encrypted keystore file with password authentication
3. Hardware Security Module (HSM) integration endpoint
4. Command-line flag: `--validator-key` (secure memory handling)

**Secure Key Storage Structure**:

| Component | Description | Security Level |
|-----------|-------------|----------------|
| Keystore File | Encrypted JSON with scrypt KDF | Medium-High |
| HSM Integration | External hardware security module | Highest |
| Environment Variable | Process-level isolation | Medium |
| In-Memory Keys | Cleared on process exit | Low |

**Validation Requirements**:
- Key format validation before acceptance
- Checksum verification for keystore files
- Secure memory wiping after key usage
- Key rotation capability without node restart

**Implementation Flow**:

1. **Key Loading Decision Tree**:
   - Check network type configuration
   - If mainnet/testnet AND no external key source → Fatal error with clear instructions
   - If devnet AND no external key → Log warning and use deterministic dev key
   - If key source provided → Validate format and permissions

2. **Keystore File Format**:
   - Standard Ethereum keystore JSON format for compatibility
   - Support for BIP-39 mnemonic phrases
   - Encrypted with user-supplied password
   - Stored in restricted-permission directory (0600 file permissions)

3. **Runtime Key Protection**:
   - Private keys never logged or persisted unencrypted
   - Memory locked using mlock() where available
   - Explicit zeroing of key material when no longer needed
   - Panic handler to prevent key leakage in stack traces

**Configuration Schema**:

```yaml
validator:
  key_source: "keystore"  # Options: keystore, hsm, env, flag
  keystore_path: "/secure/path/validator-key.json"
  hsm_endpoint: "pkcs11://slot/0/key/validator"
  require_password: true
  auto_unlock: false
```

**Error Handling Strategy**:
- Fail-fast on key loading errors (no silent defaults)
- Clear error messages directing to documentation
- Audit log of all key access attempts
- Rate limiting on password attempts

---

### 1.2 Validator BLS Key Architecture

**Problem**: Deterministic BLS key generation in `consensus/zelius.go:215-216` allows attackers to compute all validator private keys from public addresses.

**Current Vulnerable Pattern**:
```
seed := crypto.Keccak256(val.Address.Bytes())
sk := new(big.Int).SetBytes(seed)
```

**Design Solution**:

#### Independent BLS Key Registration System

**Core Principle**: Validators must generate and provide their own BLS key pairs. The system never derives private keys.

**Validator Registration Data Model**:

| Field | Type | Validation | Purpose |
|-------|------|------------|---------|
| ValidatorAddress | common.Address | Ethereum address format | Validator identity |
| Stake | *big.Int | ≥ MinimumStake | Economic security |
| BLSPublicKey | [48]byte | Valid BLS12-381 G1 point | Consensus signatures |
| ECDSAProof | [65]byte | Valid signature of BLS pubkey | Ownership proof |
| RegistrationBlock | uint64 | Current block number | Activation timing |

**BLS Key Generation Flow** (Off-Chain):

1. Validator generates fresh BLS private key using cryptographically secure randomness
2. Derives BLS public key from private key
3. Signs BLS public key with ECDSA private key (proving ownership of validator address)
4. Submits registration transaction with: `(BLSPubKey, ECDSAProof, Stake)`

**On-Chain Validation Logic**:

The system must verify the registration before accepting the validator:

**Validation Steps**:
1. **Proof Verification**: Recover ECDSA signer from ECDSAProof and verify it matches ValidatorAddress
2. **BLS Key Validation**: Deserialize BLSPublicKey and verify it represents a valid G1 point
3. **Stake Check**: Ensure staked amount meets minimum threshold
4. **Uniqueness Check**: Verify BLS public key not already registered (prevent key reuse)
5. **Rate Limiting**: Enforce cooldown period between registrations from same address

**State Storage Schema**:

```
Storage Layout in StakingAddr (0x1000):
- Key: Hash(ValidatorAddress) → Value: BLSPublicKey (48 bytes)
- Key: Hash(BLSPublicKey) → Value: ValidatorAddress (20 bytes) [Reverse lookup]
- Key: Hash("stake", ValidatorAddress) → Value: StakeAmount (32 bytes)
- Key: Hash("registration", ValidatorAddress) → Value: RegistrationBlock (8 bytes)
```

**Validator Set Synchronization**:

To ensure all nodes have consistent views of the validator set:

**Epoch-Based Activation**:
- New registrations enter a "pending" state
- Activation occurs only at epoch boundaries (every 100 blocks)
- All nodes deterministically compute the same active set at each epoch
- Prevents mid-epoch validator set changes that could cause forks

**Synchronization Algorithm**:

```
At Block N (Epoch Boundary):
1. Read all pending validator registrations from StateDB
2. Sort validators by registration block number, then by address (deterministic ordering)
3. Select top N validators by stake (N = MaxValidators)
4. Commit active validator set for epoch (N+1)
5. Broadcast validator set hash for peer verification
```

**Key Rotation Support**:

Validators may need to rotate BLS keys without unstaking:

**Rotation Procedure**:
1. Submit rotation transaction with new BLS public key and proof
2. Enter cooldown period (prevent rapid key changes)
3. New key becomes active at next epoch boundary
4. Old key remains valid until cutover block

**Migration Strategy from Current Code**:

Since existing code uses deterministic keys:

**Phase 1 - Backwards Compatibility**:
- Accept both old deterministic keys and new registered keys
- Mark deterministic keys as "legacy" in state
- Warn validators using legacy keys

**Phase 2 - Deprecation**:
- Stop accepting new deterministic key validators
- Existing legacy validators must re-register with proper keys
- Grace period: 10 epochs (1000 blocks)

**Phase 3 - Removal**:
- Hard fork to reject legacy key signatures
- All validators must use registered BLS keys

---

### 1.3 On-Chain Slashing Enforcement Mechanism

**Problem**: Slashing is tracked locally in `consensus/zelius.go:456-477` but never synchronized or enforced network-wide.

**Current Non-Functional Implementation**:
```
func (e *ZeliusEngine) Slash(addr common.Address) {
    fmt.Printf("SLASHING VALIDATOR (Zelius): %s
", addr.Hex())
    e.RemoveValidator(addr)  // Local-only, not persisted
}
```

**Design Solution**:

#### Byzantine Fault Detection and Punishment System

**Slashing Event Types**:

| Violation Type | Severity | Penalty | Detection Method |
|----------------|----------|---------|------------------|
| Double-Signing | Critical | 50% stake burn + permanent ban | Signature comparison |
| Invalid Block Proposal | High | 10% stake burn | Block verification failure |
| Prolonged Inactivity | Medium | 1% stake/epoch burn | Missed block tracking |
| Invalid VDF Proof | High | 20% stake burn | VDF verification failure |
| Vote Spamming | Medium | 5% stake burn | Rate limit violation |

**Double-Signing Proof Structure**:

A cryptographic proof that a validator signed two conflicting blocks at the same height:

**Proof Components**:
- ValidatorAddress: The accused validator
- BlockHeight: The height at which double-signing occurred
- BlockHash1: First block hash
- BlockHash2: Second block hash (must differ from BlockHash1)
- Signature1: BLS signature of BlockHash1
- Signature2: BLS signature of BlockHash2
- SubmitterAddress: Address of the node submitting the proof (reward recipient)
- SubmissionBlock: Block number when proof was submitted

**Proof Validation Logic**:

The system must verify the slashing proof before applying punishment:

**Verification Steps**:
1. **Height Match**: Verify both blocks claim the same height
2. **Block Difference**: Ensure BlockHash1 ≠ BlockHash2 (actual conflict)
3. **Validator Identity**: Extract validator address from validator set at that height
4. **Signature Verification**: 
   - Verify Signature1 is valid for BlockHash1 using validator's BLS public key
   - Verify Signature2 is valid for BlockHash2 using validator's BLS public key
5. **Timing Check**: Ensure proof is submitted within validity window (100 blocks)
6. **Duplicate Check**: Ensure this specific violation hasn't already been slashed

**Slashing Transaction Format**:

Slashing is triggered by submitting a proof transaction to a dedicated slashing contract:

**Transaction Structure**:
- **To**: SlashingAddr (0x5000 - new system contract)
- **Data**: RLP-encoded SlashingProof
- **Value**: 0 (no stake transfer)
- **Gas**: Fixed high limit (slashing computation expensive)

**On-Chain Slashing Execution**:

When a valid slashing proof is verified:

**State Changes**:
1. **Stake Reduction**:
   - Read current stake from StakingAddr storage
   - Calculate penalty amount based on violation type
   - Deduct penalty from validator's stake
   
2. **Penalty Distribution**:
   - 50% burned (sent to zero address)
   - 30% to treasury (protocol development fund)
   - 20% to proof submitter (incentivize monitoring)

3. **Validator Status Update**:
   - Add validator to blacklist (permanent ban list)
   - Remove from active validator set immediately
   - Prevent re-staking from same address

4. **Audit Trail**:
   - Emit SlashingEvent with full proof details
   - Store proof hash in slashing history
   - Log to state for dispute resolution

**State Storage Schema**:

```
Storage Layout in SlashingAddr (0x5000):
- Key: Hash("blacklist", ValidatorAddress) → Value: 1 (banned)
- Key: Hash("slashing_count") → Value: TotalSlashingEvents (counter)
- Key: Hash("slashing", EventID) → Value: RLP(SlashingProof)
- Key: Hash("penalty", ValidatorAddress, EventID) → Value: PenaltyAmount
```

**Network Synchronization**:

All nodes must reach consensus on slashing events:

**Gossip Protocol**:
- Slashing proofs are gossiped as high-priority messages
- Nodes independently verify proofs before propagation
- Invalid proofs are immediately dropped and sender reputation penalized

**Fork Resolution**:
- Slashing events are deterministic (proof-based)
- All nodes execute same slashing logic in same block
- State root includes slashing state for verification

**Incentive Alignment**:

To encourage honest monitoring:

**Proof Submitter Rewards**:
- 20% of slashed amount (significant incentive)
- First valid proof wins (prevents spam)
- Gas costs refunded for valid proofs

**Anti-Spam Measures**:
- Invalid proof submission penalized with high gas cost
- Rate limit on proof submissions per address
- Duplicate proof submissions rejected

**Implementation Phases**:

**Phase A - Detection Infrastructure** (Week 1):
- Implement double-signing detection in consensus engine
- Create SlashingProof data structure
- Build proof serialization and verification

**Phase B - On-Chain Enforcement** (Week 1-2):
- Deploy SlashingAddr system contract logic
- Implement state changes for slashing
- Add validator blacklist management

**Phase C - Network Integration** (Week 2):
- Add slashing proof gossip protocol
- Implement proof verification in block processing
- Add monitoring and alerting for slashing events

---

### 1.4 RPC Authentication and Authorization System

**Problem**: RPC endpoints in `rpc/eth_api.go` and `node/node.go:329-360` are completely unauthenticated, allowing unauthorized access to sensitive operations.

**Design Solution**:

#### Multi-Layer API Security Architecture

**Authentication Tiers**:

| Tier | Use Case | Authentication Method | Rate Limit |
|------|----------|----------------------|------------|
| Public | Read-only queries | API key (optional) | 100 req/min |
| Authenticated | Transaction submission | JWT token | 1000 req/min |
| Admin | Node management | mTLS certificate | Unlimited |
| Internal | Inter-node communication | Shared secret + mTLS | Unlimited |

**JWT Token Authentication**:

**Token Structure**:
- **Header**: Algorithm (RS256 - RSA signature)
- **Payload**: 
  - `iss`: Token issuer (node operator)
  - `sub`: Client identifier (wallet address or app ID)
  - `exp`: Expiration timestamp (24 hours default)
  - `permissions`: Array of allowed operations
  - `rate_tier`: Rate limiting tier
- **Signature**: RSA private key signature

**Token Generation Flow**:

1. Client requests token from authentication endpoint with credentials
2. System validates credentials (password, API key, or certificate)
3. System generates JWT with appropriate permissions
4. Token returned to client with expiration time
5. Client includes token in Authorization header for subsequent requests

**Permission-Based Access Control**:

RPC methods are categorized by required permission level:

**Permission Categories**:
- `read`: Query blockchain state (eth_getBalance, eth_blockNumber)
- `write`: Submit transactions (eth_sendRawTransaction)
- `admin`: Node management (admin_peers, admin_nodeInfo)
- `debug`: Debugging endpoints (debug_traceTransaction)

**Access Control Matrix**:

```
Method Permission Matrix:
- eth_blockNumber → read
- eth_getBalance → read
- eth_sendRawTransaction → write
- eth_call → read
- admin_addPeer → admin
- debug_traceBlock → debug
```

**Middleware Architecture**:

The authentication system is implemented as HTTP middleware:

**Request Processing Flow**:
1. **Rate Limiter**: Check if client has exceeded rate limit
2. **CORS Handler**: Validate cross-origin requests
3. **Authentication Middleware**: Extract and verify JWT token
4. **Authorization Middleware**: Check permissions for requested method
5. **Request Handler**: Execute RPC method
6. **Response Logger**: Log response for audit trail

**Rate Limiting Implementation**:

**Per-Client Rate Limits**:
- Token bucket algorithm with refill rate
- Separate limits per endpoint category
- Burst allowance for legitimate spikes
- Exponential backoff for repeated violations

**Rate Limit Storage**:
- In-memory cache for active clients
- Redis backend for distributed deployments
- LRU eviction for inactive clients

**Configuration Schema**:

```yaml
rpc:
  authentication:
    enabled: true
    jwt_secret_path: "/secure/jwt-secret.key"
    token_expiry: 86400  # 24 hours
    require_https: true
  
  rate_limiting:
    enabled: true
    default_limit: 100  # requests per minute
    burst_size: 200
    tiers:
      public: 100
      authenticated: 1000
      admin: unlimited
  
  cors:
    allowed_origins: ["https://app.zephyria.io"]
    allowed_methods: ["POST", "GET"]
    allow_credentials: true
  
  tls:
    enabled: true
    cert_file: "/secure/tls-cert.pem"
    key_file: "/secure/tls-key.pem"
    require_client_cert: false  # Enable for admin tier
```

**Security Best Practices**:

1. **HTTPS Enforcement**: All RPC endpoints must use TLS in production
2. **Secret Rotation**: JWT signing keys rotated every 90 days
3. **Token Revocation**: Maintain revocation list for compromised tokens
4. **Audit Logging**: Log all authentication attempts and authorization failures
5. **IP Whitelisting**: Optional IP-based access control for admin endpoints

---

### 1.5 System Contract Access Control

**Problem**: Reward distribution in `core/system_contracts.go:160-197` lacks access control, allowing unauthorized draining of the reward pool.

**Current Vulnerability**:
```
if msg.To != nil && *msg.To == rewardAddr {
    // Anyone can trigger reward distribution!
}
```

**Design Solution**:

#### Secure System Contract Authorization Framework

**Authorization Model**:

System contracts enforce strict access control based on transaction context:

**Access Control Rules**:

| Contract | Function | Authorized Caller | Validation Method |
|----------|----------|-------------------|-------------------|
| StakingAddr (0x1000) | Deposit | Any (with stake) | msg.Value > MinStake |
| StakingAddr (0x1000) | Withdraw | Staker only | msg.From == StakerAddress |
| RewardAddr (0x2000) | Distribute | Block proposer only | msg.From == header.Coinbase |
| ValidatorAddr (0x3000) | Update set | System only | Internal call during epoch |
| SlashingAddr (0x5000) | Execute | Any (with proof) | Valid slashing proof |

**Coinbase-Restricted Operations**:

The reward distribution can only be triggered by the current block's proposer:

**Validation Logic**:
1. Extract coinbase address from current block header
2. Compare with transaction sender (msg.From)
3. If mismatch → Reject transaction silently (no revert to prevent griefing)
4. If match → Proceed with reward distribution

**Automatic Reward Distribution**:

Instead of relying on explicit transactions, rewards should be distributed automatically:

**Block Finalization Rewards**:

When a block is finalized (added to canonical chain):

**Distribution Logic**:
1. **Block Proposer Reward**: 
   - Base reward: 2 ZEE per block
   - Transaction fee share: 50% of total fees in block
   - Bonus for full block: +0.5 ZEE if gas usage > 90%

2. **Validator Attestation Reward**:
   - Distributed to validators who signed the block (voted)
   - Share: 50% of transaction fees divided by number of attesters
   - Calculated from vote bitmask in block header

3. **Treasury Allocation**:
   - 10% of all rewards to treasury for protocol development
   - Accumulates in TreasuryAddr (0x6000)

**Reward Calculation Formula**:

```
Block Proposer Reward = BaseReward + (TotalFees * 0.5) + FullBlockBonus
Validator Share = (TotalFees * 0.5) / NumberOfAttesters
Treasury Share = (BlockProposerReward + TotalValidatorShares) * 0.1
```

**State Modifications**:

Reward distribution modifies StateDB during block processing:

**Balance Updates**:
1. Read validator address from block coinbase
2. Calculate reward amount based on formula
3. Transfer from RewardAddr to validator addresses
4. Update treasury balance
5. Verify RewardAddr has sufficient balance (handle depletion gracefully)

**Economic Security Parameters**:

To prevent economic attacks:

**Minimum Stake Requirements**:
- Mainnet: 1,000 ZEE (prevents Sybil attacks)
- Testnet: 100 ZEE (lower barrier for testing)
- Devnet: 1 ZEE (easy experimentation)

**Maximum Stake Cap**:
- Per validator: 1,000,000 ZEE (prevents centralization)
- Total network: Unlimited (but percentage voting power capped at 10%)

**Reward Pool Management**:

The reward pool must be sustainable:

**Pool Replenishment**:
- Genesis allocation: 10,000,000 ZEE
- Inflation rate: 5% annual (decreasing by 0.5% per year)
- Burned fees: 50% of transaction fees burned (deflationary pressure)
- Emergency refill: Governance can mint additional rewards

**Pool Monitoring**:
- Alert when balance < 100,000 ZEE
- Adjust reward rates dynamically based on remaining balance
- Prevent reward distribution if pool depleted

---

## Phase 2: Consensus Layer Hardening (Weeks 3-4)

**Priority**: 🟠 HIGH - REQUIRED FOR NETWORK STABILITY  
**Risk Level**: HIGH  
**Estimated Effort**: 60-80 hours

### 2.1 Fork Choice Rule Implementation

**Problem**: No fork choice rule exists, causing inability to resolve competing chains.

**Design Solution**:

#### Multi-Criteria Chain Selection Algorithm

**Fork Choice Philosophy**:

When multiple competing chains exist, nodes must deterministically select the canonical chain using objective criteria.

**Selection Criteria (Priority Order)**:

1. **Finality Checkpoints**: Chain with most finalized epochs
2. **Chain Length**: Longest chain among equally finalized
3. **Total Difficulty**: Accumulated PoH work (VDF iterations)
4. **Signature Weight**: Total stake that signed blocks
5. **Hash Comparison**: Lowest hash (tiebreaker)

**Finality Definition**:

A block is considered finalized when:
- 2/3+ of validators by stake have attested to it
- Block is part of an epoch that has been fully signed
- Sufficient descendant blocks exist (finality depth = 32 blocks)

**Data Structures**:

**Chain Candidate Representation**:

| Field | Type | Purpose |
|-------|------|---------|
| ChainHead | common.Hash | Tip of the chain |
| Height | uint64 | Total blocks in chain |
| FinalizedEpoch | uint64 | Last epoch with 2/3+ attestations |
| TotalVDFWork | *big.Int | Sum of VDF iterations |
| TotalStakeWeight | *big.Int | Accumulated stake of signers |
| AncestorHashes | []common.Hash | Block hashes for verification |

**Fork Choice Algorithm**:

**Selection Function**:

```
Input: Set of competing chain tips
Output: Canonical chain tip

1. Group chains by finalized epoch:
   - Find maximum finalized epoch across all chains
   - Filter chains to only those with max finalized epoch

2. Among equally finalized chains, select by length:
   - Find maximum height
   - Filter chains to only those with max height

3. If still tied, compare total VDF work:
   - Sum VDF iterations for each chain
   - Select chain with highest VDF work

4. If still tied, compare stake weight:
   - Sum signing stake for each chain
   - Select chain with highest stake weight

5. Final tiebreaker - lowest hash:
   - Compare chain head hashes lexicographically
   - Select chain with lowest hash value
```

**Implementation Location**:

Create new file: `core/fork_choice.go`

**Core Types**:

```
Type: ForkChoice struct
Fields:
- blockchain *Blockchain (reference to chain state)
- chainCandidates map[common.Hash]*ChainCandidate
- currentCanonical common.Hash
- mu sync.RWMutex (thread safety)

Methods:
- SelectCanonical([]*Block) *Block
- AddChainCandidate(*Block)
- GetFinality(common.Hash) uint64
- ComputeVDFWork(*Block) *big.Int
- CompareChains(*ChainCandidate, *ChainCandidate) int
```

**Integration Points**:

**Blockchain.AddBlock() Enhancement**:
1. Receive new block from peer
2. Validate block cryptographically
3. Determine if block creates fork
4. If fork: Trigger fork choice algorithm
5. If new canonical chain selected: Execute reorganization
6. Update chain head and notify subscribers

**Reorganization Procedure**:

When fork choice selects a different chain:

**Reorg Steps**:
1. **Find Common Ancestor**: 
   - Walk back both chains until common block found
   - This is the fork point

2. **Unwind Old Chain**:
   - Reverse state changes from fork point to old head
   - Return transactions to mempool
   - Emit reorg event with depth

3. **Apply New Chain**:
   - Execute all blocks from fork point to new head
   - Update state with new transactions
   - Remove transactions from mempool if present

4. **Update Indexes**:
   - Rewrite canonical hash indexes
   - Update block number → hash mapping
   - Clear stale receipt indexes

5. **Notify Subscribers**:
   - Emit ChainHeadEvent with new head
   - Alert monitoring systems
   - Log reorg details for debugging

**Safety Constraints**:

**Reorg Depth Limits**:
- Maximum reorg depth: 32 blocks (finality threshold)
- If reorg would exceed 32 blocks: Requires manual intervention
- Prevents catastrophic state reversals

**Finality Checkpoint Protection**:
- Cannot reorg past finalized checkpoint
- Finalized epochs are immutable
- Attempting to reorg past finality triggers alert

---

### 2.2 Validator Set Synchronization Protocol

**Problem**: Validator set changes in `consensus/zelius.go:577-661` have no consensus on activation timing.

**Design Solution**:

#### Epoch-Based Deterministic Validator Updates

**Synchronization Model**:

All validator set changes occur only at epoch boundaries to ensure network-wide consensus.

**Epoch Structure**:

| Epoch Component | Value | Purpose |
|----------------|-------|---------|
| Epoch Length | 100 blocks | Sufficient time for all nodes to sync |
| Activation Delay | 1 epoch | New validators wait one epoch before activation |
| Rotation Period | 10 epochs | Validators can update keys every 10 epochs |

**State Machine**:

**Validator Lifecycle States**:
1. **Pending**: Newly registered, awaiting activation
2. **Active**: Currently participating in consensus
3. **Rotating**: Key rotation in progress
4. **Exiting**: Unstaking initiated, awaiting unbonding
5. **Exited**: Fully withdrawn, no longer validator

**State Transitions**:

```
State Transition Rules:
- Pending → Active: At next epoch boundary after registration
- Active → Rotating: Validator submits key rotation transaction
- Rotating → Active: At epoch boundary after rotation delay
- Active → Exiting: Validator submits unstake transaction
- Exiting → Exited: After unbonding period (1000 blocks)
```

**Epoch Boundary Processing**:

At block N where N % 100 == 0:

**Update Procedure**:
1. **Snapshot Current State**:
   - Read all pending registrations from StakingAddr
   - Read all pending exits from ExitQueueAddr
   - Read all pending key rotations from ValidatorAddr

2. **Compute Next Epoch Set**:
   - Add pending validators to active set
   - Remove exited validators from active set
   - Update rotated keys for existing validators
   - Sort by stake (descending) for leader schedule

3. **Persist Validator Set**:
   - Write new validator set to dedicated state contract
   - Calculate and store validator set hash
   - Store epoch number and transition block

4. **Recalculate Consensus Parameters**:
   - Update fault tolerance threshold: f = (n-1)/3
   - Regenerate leader schedule for next epoch
   - Recompute aggregate BLS public key
   - Update vote quorum requirements

5. **Broadcast Validator Set Update**:
   - Gossip new validator set hash to all peers
   - Peers verify against own computed hash
   - Mismatch triggers sync request

**Validator Set State Storage**:

```
Storage Layout in ValidatorAddr (0x3000):
- Key: Hash("epoch", EpochNumber) → Value: ValidatorSetHash
- Key: Hash("set", EpochNumber, Index) → Value: ValidatorAddress
- Key: Hash("count", EpochNumber) → Value: ValidatorCount
- Key: Hash("active_epoch") → Value: CurrentActiveEpoch
```

**Synchronization Protocol**:

To ensure all nodes have identical validator sets:

**Consistency Verification**:
1. At epoch transition, each node computes validator set independently
2. Nodes gossip their computed validator set hash
3. If hashes match: Consensus achieved
4. If hashes differ: Trigger validator set sync protocol

**Sync Protocol**:
1. Node requests full validator list from peer
2. Peer responds with ordered validator addresses and stakes
3. Requesting node recomputes hash
4. If hash matches: Accept validator set
5. If hash still differs: Request from different peer

**Leader Schedule Computation**:

The leader schedule must be deterministic across all nodes:

**Schedule Generation Algorithm**:
1. Input: Validator set for epoch, epoch seed (VDF output)
2. For each slot in epoch (0 to 99):
   - Combine epoch seed + slot number
   - Hash combination to get random seed
   - Select leader via stake-weighted randomness
3. Output: Array of 100 leaders (one per slot)

**Stake-Weighted Selection**:

```
Weighted Random Selection:
1. Calculate total stake: S = sum(validator.stake for all validators)
2. Generate random value: R = Hash(seed + slot) % S
3. Iterate through validators:
   - Accumulate stake: acc += validator.stake
   - If acc >= R: Select this validator as leader
4. Return selected validator address
```

**Caching and Performance**:

Validator set lookups occur frequently:

**Optimization Strategies**:
- Cache current epoch's validator set in memory
- Cache next epoch's pending set for fast transition
- Index validators by address for O(1) lookup
- Precompute leader schedule at epoch start

---

### 2.3 Vote Pool Validation Enhancement

**Problem**: Vote pool in `consensus/votepool.go` accepts votes without proper validation.

**Design Solution**:

#### Comprehensive Vote Verification System

**Vote Validation Pipeline**:

Each vote passes through multiple validation stages before acceptance:

**Validation Stages**:

1. **Structural Validation**:
   - Vote has all required fields
   - Signature is correct length (96 bytes for BLS G2)
   - ValidatorIndex is within uint64 range
   - BlockHash is non-zero

2. **Temporal Validation**:
   - Vote is for current or recent block (within 100 blocks)
   - Vote is not too far in future
   - Vote has not expired (age < 30 seconds)

3. **Authority Validation**:
   - ValidatorIndex exists in current validator set
   - Validator is not in blacklist (slashed)
   - Validator has minimum stake requirement

4. **Cryptographic Validation**:
   - BLS signature verifies against validator's public key
   - Signature matches BlockHash (correct message signed)

5. **Duplicate Detection**:
   - Vote from this validator for this block not already received
   - Validator has not exceeded vote rate limit
   - Vote not identical to previously rejected vote

**Enhanced VotePool Structure**:

```
Type: VotePool struct
Fields:
- votes map[common.Hash]map[uint64]*Vote (blockHash → validatorIdx → vote)
- seenVotes map[string]bool (deduplication cache)
- voteTimestamps map[string]time.Time (for expiration)
- validatorLastVote map[uint64]time.Time (rate limiting)
- blockAge map[common.Hash]uint64 (vote freshness tracking)
- mu sync.RWMutex (thread-safe access)
- engine *ZeliusEngine (consensus context)
- blockchain *Blockchain (for block lookup)

Methods:
- AddVote(*Vote) error (with full validation)
- GetVotesForBlock(common.Hash) []*Vote
- CheckQuorum(common.Hash) (bool, []byte, []byte)
- PruneExpired() (cleanup old votes)
- GetVoteStatus(common.Hash) VoteStatus
```

**Vote Message Format**:

| Field | Type | Size | Description |
|-------|------|------|-------------|
| BlockHash | [32]byte | 32 | Hash of block being voted for |
| BlockHeight | uint64 | 8 | Height of block (for validation) |
| ValidatorIndex | uint64 | 8 | Index in validator set |
| Timestamp | uint64 | 8 | Unix timestamp of vote |
| Signature | [96]byte | 96 | BLS signature on message |

**Vote Message Signing**:

What the validator signs:

```
SignedMessage = Keccak256(
    BlockHash || 
    BlockHeight || 
    ValidatorIndex || 
    Timestamp
)
```

**Signature Verification Process**:

1. Reconstruct signed message from vote fields
2. Hash to BLS G2 point: H = HashToG2(SignedMessage, BLS_DST)
3. Retrieve validator's BLS public key: PK
4. Verify signature: e(PK, H) == e(G1, Signature)
5. If verification passes: Signature is valid

**Duplicate Detection Strategy**:

Multiple mechanisms prevent duplicate votes:

**Deduplication Keys**:
- Primary key: `Hash(BlockHash, ValidatorIndex)`
- Secondary key: `Hash(Signature)` (detect exact replays)
- Tertiary key: `Hash(ValidatorIndex, Timestamp)` (rate limit)

**Duplicate Handling**:
- If primary key exists: Reject as duplicate
- If secondary key exists but primary differs: Potential equivocation (investigate)
- If tertiary key recent: Rate limit violation (temporary reject)

**Vote Expiration**:

Votes for old blocks must be removed to prevent memory exhaustion:

**Expiration Policy**:
- Votes expire after 100 blocks (1 epoch)
- Expired votes pruned every 10 blocks
- Blocks with no votes after 50 blocks removed from tracking

**Expiration Algorithm**:

```
Prune Expired Votes:
1. Get current block height: N
2. For each block B in votePool:
   - If N - B.height > 100:
     - Remove all votes for block B
     - Delete block from vote pool
     - Free memory
3. For each validator V:
   - If V.lastVote older than 30 seconds:
     - Remove from rate limit tracker
```

**Rate Limiting**:

Prevent vote spam attacks:

**Rate Limit Parameters**:
- Maximum 1 vote per validator per block height
- Minimum 100ms between votes from same validator
- Burst allowance: 3 votes in quick succession
- Penalty for rate limit violation: Temporary ignore for 10 seconds

**Quorum Calculation**:

Determine when sufficient votes collected:

**Quorum Requirements**:
- Minimum 2/3 + 1 of total stake must vote
- Minimum 2/3 + 1 of validator count must vote
- Both conditions must be satisfied

**Quorum Computation**:

```
Check Quorum:
1. Sum total stake of all active validators: TotalStake
2. Sum stake of validators who voted: VotedStake
3. Count total validators: TotalCount
4. Count validators who voted: VotedCount
5. Calculate stake threshold: StakeThreshold = (TotalStake * 2) / 3
6. Calculate count threshold: CountThreshold = (TotalCount * 2) / 3
7. If VotedStake > StakeThreshold AND VotedCount > CountThreshold:
   - Quorum achieved
   - Aggregate signatures
   - Return quorum certificate
8. Else: Quorum not achieved, continue waiting
```

**Signature Aggregation**:

When quorum achieved, aggregate individual signatures:

**Aggregation Process**:
1. Initialize aggregate signature: AggSig = G2.Identity()
2. Initialize bitmask: Bitmask = [0, 0, ..., 0] (length = ceil(validatorCount/8))
3. For each vote in quorum:
   - Deserialize vote signature to G2 point
   - Add to aggregate: AggSig += VoteSignature
   - Set bit in bitmask: Bitmask[validatorIdx/8] |= (1 << (validatorIdx%8))
4. Serialize aggregate signature: AggSigBytes = AggSig.Marshal()
5. Return (AggSigBytes, Bitmask)

**Vote Pool Monitoring**:

Track metrics for observability:

**Metrics to Collect**:
- Total votes received per block
- Average time to quorum
- Percentage of validators participating
- Vote rejection reasons (rate limit, invalid signature, etc.)
- Memory usage of vote pool

---

### 2.4 VDF Verification Hardening

**Problem**: VDF verification in `consensus/zelius.go:346` lacks comprehensive checks.

**Design Solution**:

#### Multi-Layer VDF Proof Validation

**VDF Security Properties**:

The VDF must guarantee:
1. **Sequential Computation**: Cannot be parallelized or precomputed
2. **Efficient Verification**: Fast to verify despite slow to compute
3. **Uniqueness**: Each input produces unique output
4. **Determinism**: Same input always produces same output

**VDF Proof Structure**:

| Component | Size | Purpose |
|-----------|------|---------|
| Input | 32 bytes | Starting value (parent VDF output or hash) |
| Output | 32 bytes | Final VDF result |
| Checkpoints | 5 × 32 bytes | Intermediate values for verification |
| Iterations | 8 bytes | Number of squaring operations |

**Comprehensive Verification Algorithm**:

**Verification Steps**:

1. **Input Validation**:
   - Verify input is correct (matches parent's last checkpoint)
   - Ensure input is in correct domain (valid field element)
   - Check input is not from future block

2. **Checkpoint Verification**:
   - Verify each checkpoint is correctly computed from previous
   - Use parallelization to speed up verification
   - Ensure no checkpoint is zero or identity element

3. **Timing Validation**:
   - Calculate expected computation time: T = Iterations / ComputeRate
   - Verify block timestamp: BlockTime ≥ ParentTime + T
   - Reject if VDF appears precomputed (too fast)

4. **Uniqueness Check**:
   - Verify VDF output not seen before (prevent replay)
   - Check VDF output differs from parent (prevent copying)
   - Ensure output is deterministic (compare with recomputation)

5. **Chain Linkage**:
   - Verify VDF forms continuous chain from genesis
   - Check no gaps or breaks in VDF sequence
   - Validate each block's VDF links to parent

**Implementation Location**:

Enhance existing `consensus/vdf/vdf.go`

**New Verification Methods**:

```
Method: VerifyStrict(input, output []byte, checkpoints [][]byte, iterations int) error
Purpose: Comprehensive verification with all checks
Returns: nil if valid, descriptive error if invalid

Method: VerifyTiming(blockTime, parentTime uint64, iterations int) error
Purpose: Ensure VDF was not precomputed
Returns: nil if timing valid, error if suspicious

Method: CheckUniqueness(output []byte, seenVDFs map[string]bool) error
Purpose: Prevent VDF replay attacks
Returns: nil if unique, error if duplicate

Method: VerifyLinkage(parentVDF []byte, currentInput []byte) error
Purpose: Ensure VDF chain continuity
Returns: nil if linked, error if broken chain
```

**VDF Replay Prevention**:

Maintain database of seen VDF outputs:

**Storage Strategy**:
- Store last 1000 VDF outputs in memory (recent)
- Store all VDF outputs in database (historical)
- Key: VDF output hash
- Value: Block height where VDF appeared

**Replay Detection**:

```
Check for Replay:
1. Hash VDF output: OutputHash = Keccak256(VDFOutput)
2. Query seenVDFs map: PreviousBlock = seenVDFs[OutputHash]
3. If PreviousBlock exists and != 0:
   - VDF output previously seen at block PreviousBlock
   - Reject as replay attack
4. Else:
   - VDF output is unique
   - Add to seenVDFs map
   - Proceed with validation
```

**Timing Attack Prevention**:

Ensure VDF was computed in real-time:

**Timing Validation**:

```
Validate VDF Timing:
1. Read parent block timestamp: ParentTime
2. Read current block timestamp: CurrentTime
3. Calculate minimum required time:
   MinTime = (Iterations * NanosecondsPerSquare) / 1e9
4. Calculate actual time delta:
   ActualDelta = CurrentTime - ParentTime
5. If ActualDelta < MinTime * 0.9:  // 10% tolerance
   - VDF appears precomputed
   - Reject block
6. If ActualDelta > MinTime * 10:  // Reasonable upper bound
   - Block delayed too long (possible stalling attack)
   - Log warning but accept (liveness over safety)
7. Else:
   - Timing is reasonable
   - Accept VDF
```

**Performance Optimization**:

VDF verification is computationally expensive:

**Optimization Strategies**:
1. **Parallel Verification**: Verify multiple checkpoints simultaneously
2. **Caching**: Cache verification results for seen blocks
3. **Fast Path**: Skip full verification for finalized blocks
4. **Hardware Acceleration**: Use AVX2/AVX-512 for field arithmetic

**Parallel Verification Algorithm**:

```
Parallel Checkpoint Verification:
1. Divide checkpoints into groups (one per CPU core)
2. Spawn goroutine for each group
3. Each goroutine verifies its checkpoints independently
4. Wait for all goroutines to complete
5. If any goroutine reports failure: Reject VDF
6. If all goroutines succeed: Accept VDF

Speedup: ~4-8x with modern CPUs
```

**VDF Parameter Configuration**:

Different networks require different VDF difficulty:

| Network | Iterations | Checkpoint Interval | Expected Time |
|---------|-----------|---------------------|---------------|
| Mainnet | 800,000 | 12,500 | ~400ms |
| Testnet | 400,000 | 6,250 | ~200ms |
| Devnet | 100,000 | 1,250 | ~50ms |

**Adaptive VDF Difficulty**:

Adjust VDF iterations based on network conditions:

**Adjustment Algorithm**:
1. Measure average block time over last 100 blocks
2. If average < target - 10%: Increase iterations by 5%
3. If average > target + 10%: Decrease iterations by 5%
4. Apply adjustment at next epoch boundary
5. Limit adjustment rate to prevent oscillation

---

### 2.5 Entropy Source Enhancement

**Problem**: Leader selection randomness in `consensus/zelius.go:523-526` is predictable.

**Design Solution**:

#### Multi-Source Entropy Mixing System

**Randomness Sources**:

Combine multiple unpredictable sources:

1. **VDF Output**: Proof-of-History checkpoint (slow, unpredictable)
2. **VRF Randomness**: Validator-generated verifiable randomness
3. **Block Hash**: Previous block hash (dependent on transactions)
4. **Timestamp**: Block timestamp (slight unpredictability)
5. **External Beacon**: Drand public randomness beacon (optional)

**Entropy Mixing Algorithm**:

```
Generate Leader Selection Seed:
1. Collect entropy sources:
   - vdfOutput = ExtractLastVDFCheckpoint(parentBlock)
   - vrfOutput = ExtractVRFOutput(parentBlock)
   - blockHash = parentBlock.Hash()
   - timestamp = parentBlock.Timestamp
   - [optional] beaconValue = QueryDrand(roundNumber)

2. Concatenate all sources:
   entropyInput = vdfOutput || vrfOutput || blockHash || timestamp || beaconValue

3. Hash to produce final seed:
   leaderSeed = Keccak256(entropyInput || slotNumber)

4. Use seed for stake-weighted selection:
   leader = SelectLeaderByStake(leaderSeed, validatorSet)
```

**VRF Integration**:

Each validator generates VRF proof to contribute entropy:

**VRF Proof Generation** (by block proposer):
1. Input: EpochSeed || BlockNumber
2. Compute VRF: (Output, Proof) = VRF_Prove(ValidatorBLSKey, Input)
3. Include in block: ExtraData = VDFCheckpoints || VRFOutput || VRFProof
4. VRFOutput contributes to next block's leader selection

**VRF Verification** (by all nodes):
1. Extract VRFOutput and VRFProof from block
2. Reconstruct input: Input = EpochSeed || BlockNumber
3. Verify: VRF_Verify(ValidatorBLSPubKey, Input, VRFOutput, VRFProof)
4. If valid: Accept VRFOutput as entropy source
5. If invalid: Reject block

**Drand Integration** (Optional):

For additional unpredictability, integrate drand public randomness:

**Drand Usage**:
- Drand is a distributed randomness beacon
- Provides unpredictable, publicly verifiable randomness
- New random value every 30 seconds

**Integration Steps**:
1. Query drand API for latest randomness round
2. Verify randomness signature against drand public key
3. Mix drand randomness into leader selection seed
4. Fallback: If drand unavailable, skip this entropy source

**Configuration**:
```yaml
consensus:
  randomness:
    sources:
      - vdf       # Always enabled
      - vrf       # Always enabled
      - block_hash # Always enabled
      - timestamp  # Always enabled
      - drand     # Optional, can be disabled
    drand:
      enabled: false
      url: "https://drand.cloudflare.com"
      chain_hash: "8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce"
```

**Leader Selection Algorithm**:

With improved entropy:

```
Select Leader for Slot:
1. Generate mixed entropy seed (as above)
2. Calculate total stake: TotalStake = sum(validator.stake)
3. Derive selection value: SelectionValue = seed % TotalStake
4. Iterate through validators (sorted by address for determinism):
   accumulator = 0
   for validator in validators:
     accumulator += validator.stake
     if accumulator >= SelectionValue:
       return validator as leader
5. Fallback: Return first validator (should never reach here)
```

**Predictability Analysis**:

Analyze how far ahead leader schedule can be predicted:

**Predictability Horizon**:
- With VDF only: 1-2 blocks ahead (VDF computation time)
- With VRF: 1 block ahead (VRF in current block affects next)
- With Drand: Unpredictable until drand reveals randomness

**Security Properties**:
- VDF prevents precomputation attacks
- VRF prevents bias by validator
- Block hash prevents manipulation via transaction ordering
- Drand adds external unpredictability

---

## Phase 3: State Management & Persistence (Weeks 5-6)

**Priority**: 🟡 HIGH - LONG-TERM OPERABILITY  
**Risk Level**: MEDIUM-HIGH  
**Estimated Effort**: 50-70 hours

### 3.1 State Pruning System

**Problem**: State in `state/statedb.go` grows indefinitely without pruning.

**Design Solution**:

#### Multi-Level State Retention Architecture

**Pruning Strategy**:

Maintain multiple state versions with different retention policies:

**Retention Tiers**:

| Tier | Retention | Purpose | Storage Overhead |
|------|-----------|---------|------------------|
| Recent | Last 128 blocks | Fast reorg support | 100% |
| Checkpoint | Every 1000 blocks | Historical queries | 10% |
| Archive | All blocks | Full history (optional) | 100% |

**State Version Management**:

**Versioned Key Format**:
```
Current Format: "v" + key
New Format: "v" + blockNumber + ":" + key
```

**Version Metadata**:
```
Metadata Key: "state_version_" + blockNumber
Metadata Value: {
  BlockHash: common.Hash
  StateRoot: common.Hash
  Timestamp: uint64
  IsPruned: bool
}
```

**Pruning Algorithm**:

```
Prune Old State:
1. Determine current block height: CurrentHeight
2. Calculate prune threshold: PruneUntil = CurrentHeight - RetentionBlocks
3. If PruneUntil % 1000 == 0:  // Checkpoint block, keep it
   skip pruning for this version
4. Iterate through state versions:
   for version in range(OldestVersion, PruneUntil):
     if version % 1000 != 0:  // Not a checkpoint
       DeleteStateVersion(version)
       MarkVersionPruned(version)
5. Compact database to reclaim space
6. Update pruning metadata
```

**State Snapshot System**:

Periodic state snapshots for fast sync:

**Snapshot Structure**:
```
Snapshot {
  BlockNumber: uint64
  StateRoot: common.Hash
  ValidatorSetHash: common.Hash
  AccountCount: uint64
  SerializedState: []byte  // Merkle tree dump
  Signature: []byte  // Validator signatures
}
```

**Snapshot Generation**:

```
Create Snapshot at Checkpoint:
1. Identify checkpoint block (every 1000 blocks)
2. Export full state from Verkle tree:
   - Serialize tree structure
   - Include all account balances
   - Include all contract storage
   - Compress with Snappy
3. Calculate snapshot hash
4. Collect validator signatures (for authenticity)
5. Store snapshot to disk and/or distribute via P2P
6. Keep last 10 snapshots locally
```

**Fast Sync from Snapshot**:

New nodes can sync from snapshot:

```
Fast Sync Process:
1. Request latest snapshot from peers
2. Verify snapshot signatures (2/3+ validators)
3. Download and decompress snapshot
4. Import state tree into local database
5. Verify state root matches snapshot
6. Resume normal sync from snapshot block forward
```

**Database Compaction**:

After pruning, compact LevelDB:

```
Compact Database:
1. Close write operations (pause block processing)
2. Run LevelDB compaction:
   db.CompactRange(util.Range{Start: nil, Limit: nil})
3. Reopen write operations
4. Monitor compaction progress
5. Report disk space reclaimed
```

**Configuration**:

```yaml
state:
  pruning:
    enabled: true
    retention_blocks: 128  # Keep recent 128 blocks
    checkpoint_interval: 1000  # Checkpoint every 1000 blocks
    prune_interval: 100  # Run pruning every 100 blocks
    
  snapshots:
    enabled: true
    interval: 1000  # Create snapshot every 1000 blocks
    retain_count: 10  # Keep 10 most recent snapshots
    
  database:
    compact_interval: 86400  # Compact once per day (seconds)
    max_file_size: 2147483648  # 2GB max file size
```

---

### 3.2 State Root Verification

**Problem**: Blocks are added in `core/blockchain.go:88-123` without verifying state root.

**Design Solution**:

#### Block Execution Verification Pipeline

**Verification Strategy**:

Every block must be re-executed before acceptance:

**Verification Steps**:

1. **Retrieve Parent State**: Load state at parent block's state root
2. **Create State Overlay**: Create temporary state for execution
3. **Re-Execute Block**: Apply all transactions in order
4. **Calculate State Root**: Compute Merkle root after execution
5. **Compare Roots**: Verify computed root matches block's claimed root
6. **Verify Receipts**: Ensure transaction receipts match
7. **Accept or Reject**: Only add block if all verifications pass

**Implementation Location**:

Enhance `core/blockchain.go` `AddBlock()` method

**Verification Algorithm**:

```
Verify and Add Block:
1. Validate block structure (existing checks)
2. Retrieve parent block:
   parent = blockchain.GetBlockByHash(block.ParentHash)
   if parent == nil:
     return ErrParentNotFound
     
3. Load parent state:
   parentState = blockchain.StateAt(parent.StateRoot)
   if parentState == nil:
     return ErrStateNotAvailable
     
4. Create execution overlay:
   executionState = parentState.NewOverlay()
   
5. Re-execute block:
   executor = NewExecutor(chainConfig, networkConfig, blockchain)
   receipts, stateRoot, gasUsed, err = executor.ApplyBlock(
     executionState, 
     block.Header, 
     block.Transactions
   )
   if err != nil:
     return ErrBlockExecutionFailed
     
6. Verify state root:
   if stateRoot != block.Header.VerkleRoot:
     return ErrStateRootMismatch
     
7. Verify receipts:
   expectedReceiptHash = DeriveSha(receipts)
   if expectedReceiptHash != block.Header.ReceiptHash:
     return ErrReceiptHashMismatch
     
8. Verify gas used:
   if gasUsed != block.Header.GasUsed:
     return ErrGasUsedMismatch
     
9. All verifications passed, commit state:
   executionState.Commit(blockchain.db)
   
10. Add block to blockchain:
    blockchain.addBlockUnsafe(block, receipts)
    
11. Return success
```

**Receipt Verification**:

Ensure transaction receipts are correct:

**Receipt Comparison**:
```
Compare Receipts:
1. Verify same number of receipts as transactions
2. For each receipt:
   - Compare transaction hash
   - Compare status (success/failure)
   - Compare gas used
   - Compare logs (events)
   - Compare bloom filter
3. All receipts must match exactly
```

**Execution Cache**:

Avoid redundant re-execution:

**Caching Strategy**:
- Cache execution results for recently verified blocks
- Key: BlockHash
- Value: (StateRoot, Receipts, GasUsed)
- TTL: 100 blocks or 15 minutes

**Cache Usage**:
```
Check Execution Cache:
1. Query cache: result = cache.Get(block.Hash())
2. If result exists and fresh:
   - Use cached state root and receipts
   - Skip re-execution
3. Else:
   - Perform full re-execution
   - Store result in cache
```

**Error Handling**:

Different failure modes require different responses:

| Error Type | Response | Reason |
|------------|----------|--------|
| ErrParentNotFound | Request sync | Missing chain history |
| ErrStateNotAvailable | Request state sync | State pruned or corrupted |
| ErrStateRootMismatch | Reject block, ban peer | Invalid block |
| ErrReceiptHashMismatch | Reject block, ban peer | Invalid receipts |
| ErrBlockExecutionFailed | Reject block | Invalid transactions |

---

### 3.3 Concurrent State Access Safety

**Problem**: State overlays in `state/statedb.go:169-189` have potential race conditions.

**Design Solution**:

#### Thread-Safe State Access Layer

**Concurrency Model**:

State access follows strict locking protocol:

**Lock Hierarchy**:
1. **Read Lock**: Allows multiple concurrent readers
2. **Write Lock**: Exclusive access for state modifications
3. **Overlay Lock**: Per-overlay lock for nested states

**StateDB Synchronization**:

```
Enhanced StateDB struct:
- rwMutex sync.RWMutex (protects state reads/writes)
- overlayMutex sync.Mutex (protects overlay creation)
- snapshotID uint64 (version tracking)
- parent *StateDB (parent state reference)
- parentSnapshot uint64 (parent version at overlay creation)
```

**Thread-Safe Operations**:

**Read Operation**:
```
Get Balance:
1. Acquire read lock: s.rwMutex.RLock()
2. Defer unlock: defer s.rwMutex.RUnlock()
3. Check parent snapshot validity:
   if s.parent != nil && s.parentSnapshot != s.parent.snapshotID:
     panic("parent state changed")
4. Perform read from tree or parent
5. Return value (lock automatically released)
```

**Write Operation**:
```
Set Balance:
1. Acquire write lock: s.rwMutex.Lock()
2. Defer unlock: defer s.rwMutex.Unlock()
3. Increment snapshot ID: s.snapshotID++
4. Write to dirty cache: s.dirty[key] = value
5. Mark key as modified: s.journal.append(change)
6. Return (lock automatically released)
```

**Overlay Creation**:
```
Create Overlay:
1. Acquire overlay lock: s.overlayMutex.Lock()
2. Defer unlock: defer s.overlayMutex.Unlock()
3. Acquire parent read lock: s.rwMutex.RLock()
4. Capture parent snapshot: snapshotID = s.snapshotID
5. Release parent read lock: s.rwMutex.RUnlock()
6. Create new overlay:
   overlay = &StateDB{
     parent: s,
     parentSnapshot: snapshotID,
     dirty: make(map[string][]byte),
     snapshotID: 0,
   }
7. Return overlay
```

**Snapshot Validation**:

Detect stale parent references:

```
Validate Parent Snapshot:
Purpose: Ensure parent hasn't changed since overlay creation
Called: Before every read from parent

Algorithm:
1. If s.parent == nil: return (no parent)
2. If s.parentSnapshot != s.parent.snapshotID:
   - Parent state has been modified
   - Overlay is now invalid
   - Panic with clear error message
3. Return (parent snapshot is valid)
```

**Aquarius Scheduler Integration**:

Parallel execution requires careful state isolation:

**Execution Wave Safety**:
```
Execute Transaction Wave:
1. Create isolated overlay for each transaction:
   overlays = make([]*StateDB, len(wave))
   for i, tx := range wave:
     overlays[i] = baseState.NewOverlay()
     
2. Execute transactions in parallel:
   var wg sync.WaitGroup
   for i, tx := range wave:
     wg.Add(1)
     go func(idx int, tx *Transaction) {
       defer wg.Done()
       ExecuteTransaction(overlays[idx], tx)
     }(i, tx)
   wg.Wait()
   
3. Merge overlays sequentially (deterministic order):
   for _, overlay := range overlays:
     baseState.MergeOverlay(overlay)
     
4. Commit merged state:
   baseState.Commit()
```

**Deadlock Prevention**:

Avoid lock ordering issues:

**Lock Ordering Rules**:
1. Always acquire locks in hierarchy order (parent before child)
2. Never hold lock while waiting for another resource
3. Use timeouts on lock acquisition
4. Release locks in reverse order of acquisition

**Configuration**:

```yaml
state:
  concurrency:
    enable_locking: true  # Enable thread-safe access
    lock_timeout: 30s  # Maximum time to wait for lock
    detect_deadlocks: true  # Enable deadlock detection
    max_overlays: 1000  # Limit concurrent overlays
```

---

## Phase 4: Network Security (Weeks 7-8)

**Priority**: 🟠 HIGH - NETWORK RESILIENCE  
**Risk Level**: HIGH  
**Estimated Effort**: 40-60 hours

### 4.1 Peer Reputation System

**Problem**: Peers in `p2p/server.go:239-264` are accepted without authentication.

**Design Solution**:

#### Multi-Dimensional Peer Scoring

**Reputation Model**:

Each peer is scored across multiple dimensions:

**Reputation Dimensions**:

| Dimension | Weight | Range | Impact |
|-----------|--------|-------|--------|
| Validity | 40% | 0-100 | Valid vs invalid messages |
| Responsiveness | 20% | 0-100 | Response time and availability |
| Bandwidth | 15% | 0-100 | Data transfer efficiency |
| Uptime | 15% | 0-100 | Connection stability |
| Stake | 10% | 0-100 | Economic commitment (validators) |

**Reputation Calculation**:
```
TotalScore = (Validity * 0.4) + 
             (Responsiveness * 0.2) + 
             (Bandwidth * 0.15) + 
             (Uptime * 0.15) + 
             (Stake * 0.1)
```

**Peer Reputation Structure**:

```
Type: PeerReputation struct
Fields:
- PeerID enode.ID
- ValidMessages uint64
- InvalidMessages uint64
- ResponseTimes []time.Duration (last 100)
- BytesSent uint64
- BytesReceived uint64
- ConnectionStart time.Time
- LastSeen time.Time
- DisconnectCount uint64
- BanScore int
- StakedAmount *big.Int (if validator)
```

**Reputation Update Events**:

| Event | Score Change | Reason |
|-------|--------------|--------|
| Valid Block | +5 | Contributed useful data |
| Invalid Block | -20 | Wasted resources |
| Fast Response | +2 | Good network citizen |
| Timeout | -5 | Unreliable |
| Connection Drop | -3 | Unstable connection |
| Rate Limit Violation | -15 | Potential attack |
| Successful Sync | +10 | Helpful peer |

**Banning Policy**:

**Ban Thresholds**:
- BanScore > 100: Permanent ban
- BanScore 50-100: Temporary ban (24 hours)
- BanScore 25-50: Throttled (reduced rate limits)
- BanScore < 25: Normal operation

**Ban Decay**:
- BanScore decreases by 1 per hour
- Good behavior accelerates decay
- Bans expire after threshold drops below 25

**Peer Handshake Protocol**:

Enhanced handshake with authentication:

**Handshake Message**:
```
HandshakeMessage {
  ProtocolVersion: uint32
  NetworkID: uint64
  GenesisHash: common.Hash
  BestBlockHash: common.Hash
  BestBlockHeight: uint64
  TotalDifficulty: *big.Int
  ValidatorPubKey: []byte (optional, if validator)
  Capabilities: []string
  Timestamp: uint64
  Signature: []byte (sign entire message)
}
```

**Handshake Verification**:
```
Verify Peer Handshake:
1. Check protocol version compatibility
2. Verify network ID matches
3. Verify genesis hash matches
4. Check block height is reasonable (not too far ahead)
5. Verify signature using peer's ECDSA public key
6. If validator: Verify validator public key is registered
7. Check capabilities match expected
8. Verify timestamp is recent (within 30 seconds)
```

**Peer Selection Algorithm**:

When connecting to new peers:

```
Select Peer to Connect:
1. Query peer database for candidates
2. Filter by:
   - Not already connected
   - Not banned
   - Compatible protocol version
3. Sort by reputation score (descending)
4. Prefer validators (if we need validator connections)
5. Select top N peers
6. Attempt connections in parallel
7. Accept first successful connection
```

**Peer Eviction Policy**:

When at max peer limit:

```
Evict Low-Quality Peer:
1. Calculate scores for all peers
2. Identify lowest-scored non-validator peer
3. If new peer score > lowest peer score:
   - Disconnect lowest peer
   - Connect to new peer
4. Else:
   - Reject new peer
   - Keep existing connections
```

**Configuration**:

```yaml
p2p:
  reputation:
    enabled: true
    ban_threshold: 100
    temp_ban_duration: 86400  # 24 hours
    score_decay_rate: 1  # Per hour
    
  peer_limits:
    max_peers: 50
    max_validators: 20
    min_validators: 5
    max_inbound: 30
    max_outbound: 20
```

---

### 4.2 Message Rate Limiting

**Problem**: No rate limiting on P2P messages in `p2p/handlers.go`.

**Design Solution**:

#### Hierarchical Rate Limiting System

**Rate Limit Hierarchy**:

1. **Global Limits**: Per node total message rate
2. **Per-Peer Limits**: Individual peer message rate
3. **Per-Message-Type Limits**: Different limits for different messages
4. **Burst Allowances**: Temporary exceeding of limits

**Rate Limit Configuration**:

| Message Type | Limit (per second) | Burst | Violation Penalty |
|--------------|-------------------|-------|-------------------|
| Block | 10 | 20 | -20 reputation |
| Transaction | 100 | 200 | -5 reputation |
| Vote | 50 | 100 | -10 reputation |
| Sync Request | 5 | 10 | -3 reputation |
| Shred | 200 | 400 | -15 reputation |

**Token Bucket Algorithm**:

Use token bucket for smooth rate limiting:

**Token Bucket Parameters**:
- **Capacity**: Maximum tokens (burst size)
- **Refill Rate**: Tokens added per second
- **Current Tokens**: Available tokens

**Algorithm**:
```
Check Rate Limit:
1. Calculate time since last refill: elapsed = now - lastRefill
2. Calculate tokens to add: newTokens = elapsed * refillRate
3. Update token count: tokens = min(tokens + newTokens, capacity)
4. Update last refill time: lastRefill = now
5. If tokens >= 1:
   - Consume 1 token
   - Allow message
   - Return true
6. Else:
   - Rate limit exceeded
# Production-Ready Implementation: Critical Security Fixes & Core Infrastructure

## Project Context

Zephyria is a high-performance, EVM-compatible Layer-1 blockchain featuring the Zelius consensus mechanism (PoS-based BFT with deterministic leader scheduling and VDF-based Proof-of-History). The codebase demonstrates strong architectural foundations with innovative features, currently achieving 3,000-5,000 TPS in development environments.

### Current State Assessment

The system is in development/PoC phase with multiple critical security vulnerabilities and incomplete implementations that block production deployment. Analysis of `SECURITY_AND_IMPLEMENTATION_GAPS.md` identifies 5 critical issues, 8 high-priority issues, and numerous medium-priority gaps requiring immediate attention.

**Risk Level**: CRITICAL - System is NOT production-ready and should not be deployed to mainnet in current state.

## Strategic Objectives

Transform the Zephyria blockchain from proof-of-concept to production-ready state by implementing comprehensive security fixes, consensus hardening, and operational infrastructure. Focus on addressing critical vulnerabilities first, then systematic enhancement of reliability, security, and performance.

### Success Criteria

- Zero critical security vulnerabilities remaining
- All consensus mechanisms provably secure with proper Byzantine fault tolerance
- State management with proper pruning, verification, and persistence guarantees
- Network layer resistant to eclipse, sybil, and DoS attacks
- Complete test coverage with multi-node integration tests passing
- Production-grade monitoring and observability infrastructure
- Clear operational runbooks for validator deployment and maintenance

## Implementation Priorities

### Priority Classification

This design organizes work into 8 phases based on blocking severity and dependencies:

- **Phase 1 (CRITICAL)**: Blocks any deployment - must complete before testnet
- **Phase 2 (HIGH)**: Required for network stability - must complete before mainnet
- **Phase 3 (HIGH)**: Required for long-term operation
- **Phase 4 (HIGH)**: Network resilience requirements
- **Phase 5 (MEDIUM)**: Economic security and user experience
- **Phase 6 (MEDIUM)**: API hardening and developer experience
- **Phase 7 (MEDIUM)**: Performance optimization
- **Phase 8 (LOW)**: Future enhancements

### Effort Estimation Framework

| Phase | Estimated Hours | Risk Level | Team Size Recommendation |
|-------|----------------|------------|-------------------------|
| Phase 1 | 40-60 | CRITICAL | 2-3 Senior Engineers |
| Phase 2 | 60-80 | HIGH | 2-3 Senior Engineers |
| Phase 3 | 50-70 | HIGH | 2 Senior Engineers |
| Phase 4 | 40-60 | HIGH | 2 Senior Engineers |
| Phase 5 | 30-40 | MEDIUM | 1-2 Engineers |
| Phase 6 | 40-50 | MEDIUM | 1-2 Engineers |
| Phase 7 | 30-40 | MEDIUM | 1-2 Engineers |
| Phase 8 | 80-100 | LOW | 1-2 Engineers |

**Total Estimated Timeline**: 16-24 weeks with proper team allocation

---

## Phase 1: Critical Security Fixes (IMMEDIATE)

**Objective**: Eliminate catastrophic security vulnerabilities that would lead to immediate compromise if deployed.

**Timeline**: Week 1-2 (40-60 hours)

### 1.1 Cryptographic Key Management Overhaul

#### Problem Statement

**Location**: `core/genesis.go:26`, `cmd/zephyria/main.go:60`

The system contains hardcoded private key `DefaultDevKey` used as fallback for production networks. Additionally, BLS private keys are derived deterministically from validator addresses at `consensus/zelius.go:215-216`, making all keys publicly computable.

**Current Implementation**:
- Hardcoded ECDSA private key: `ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`
- BLS key derivation: `seed := crypto.Keccak256(val.Address.Bytes())`
- Any attacker can compute all validator private keys

**Impact**: Complete compromise of consensus security, catastrophic fund loss, validator impersonation.

#### Design Solution

**Secure Key Management Architecture**

Create multi-layered key management system with network-specific enforcement:

**Key Requirements**:
1. Validators must provide their own BLS public keys during registration
2. No deterministic key derivation from addresses
3. Mandatory key provision for non-development networks
4. Secure key storage with encryption at rest
5. Key rotation support for long-term security

**System Components**:

**Component A: Network-Aware Key Enforcement**

Location: `cmd/zephyria/main.go`

Behavior specification:
- Detect network type from configuration (mainnet, testnet, devnet)
- For mainnet/testnet: Terminate with fatal error if no private key provided
- For devnet: Allow DefaultDevKey but emit warning banner to console
- Validate key format before acceptance (64-character hex for ECDSA)
- Log all key operations with appropriate security level

**Component B: BLS Public Key Registration System**

Location: `consensus/zelius.go`, `core/system_contracts.go`

Modify validator data structure:
- Remove all deterministic key derivation logic
- Require 48-byte BLS public key during validator registration
- Validate BLS public key format using BLS12-381 curve verification
- Store provided public keys in validator state without derivation
- Reject staking transactions without valid BLS public key

**Component C: Staking Contract Enhancement**

Location: `core/system_contracts.go:74-100`

Staking transaction data structure requirements:
- Byte layout: `[STAKE_COMMAND][BLS_PUBLIC_KEY_48_BYTES][PADDING]`
- Validation rules: Verify public key lies on BLS12-381 G1 curve
- State storage: Map validator address to provided BLS public key
- Rejection criteria: Missing key, invalid format, wrong curve

**Component D: Secure Key Storage Subsystem**

Location: New package `keystore/`

Functionality specification:
- Encrypt private keys at rest using AES-256-GCM
- Derive encryption key from user-provided password using Argon2id
- Store encrypted keyfiles in standardized format (similar to Ethereum keystore)
- Implement secure key loading on node startup
- Support hardware security module (HSM) integration path for future

**Key File Format**:
```
Encrypted Keystore Structure (JSON):
{
  "version": "1",
  "crypto": {
    "cipher": "aes-256-gcm",
    "ciphertext": "<encrypted_private_key>",
    "cipherparams": {
      "iv": "<initialization_vector>"
    },
    "kdf": "argon2id",
    "kdfparams": {
      "salt": "<random_salt>",
      "iterations": 4,
      "memory": 65536,
      "parallelism": 2
    },
    "mac": "<message_authentication_code>"
  },
  "id": "<uuid>",
  "address": "<validator_address>",
  "bls_public_key": "<48_byte_bls_pubkey_hex>"
}
```

#### Validation Requirements

**Pre-Deployment Validation**:
1. Attempt to start mainnet node without key - must fail with clear error
2. Attempt to start testnet node without key - must fail with clear error
3. Attempt to start devnet node without key - succeeds with warning
4. Provide invalid BLS public key to staking - transaction must be rejected
5. Verify no deterministic key derivation code paths remain

**Security Checklist**:
- [ ] All hardcoded private keys removed from production code paths
- [ ] BLS key derivation functions deleted or isolated to devnet-only paths
- [ ] Keystore encryption tested with multiple passwords
- [ ] Key file permissions set to 0600 (owner read/write only)
- [ ] Memory containing keys securely zeroed after use

#### Migration Strategy

For existing devnet/testnet deployments:
1. Generate proper BLS keypairs for all validators
2. Re-register validators with correct public keys
3. Coordinate epoch boundary for simultaneous validator set update
4. Retain old code in separate branch for comparison testing only

---

### 1.2 Slashing Enforcement System

#### Problem Statement

**Location**: `consensus/zelius.go:456-477`

Slashing is tracked locally but never synchronized across network. Malicious validators face no economic consequences for Byzantine behavior (double-signing, invalid blocks, censorship).

**Current Implementation**:
```
func (e *ZeliusEngine) Slash(addr common.Address) {
    fmt.Printf("SLASHING VALIDATOR (Zelius): %s
", addr.Hex())
    e.RemoveValidator(addr)  // Local only, not persisted or gossiped
}
```

**Impact**: No deterrent for malicious behavior, Byzantine validators can attack without consequences, consensus security fundamentally broken.

#### Design Solution

**On-Chain Slashing with Cryptographic Proofs**

Implement verifiable slashing mechanism with proof distribution, on-chain execution, and permanent state persistence.

**System Architecture**:

**Component A: Slashing Proof Structure**

Define cryptographically verifiable proof of misbehavior:

**Double-Signing Proof Format**:
- Validator address (20 bytes)
- Block height (8 bytes)
- First block hash (32 bytes)
- Second block hash (32 bytes) - must differ from first
- First BLS signature (96 bytes)
- Second BLS signature (96 bytes)
- Proof submitter address (20 bytes)
- Timestamp (8 bytes)

**Proof Validity Conditions**:
1. Both blocks at same height
2. Block hashes differ (equivocation)
3. Both signatures verify against validator's BLS public key
4. Validator was active at specified height
5. Proof not previously submitted (no double-slashing)

**Component B: Slashing Transaction Processing**

Location: `core/system_contracts.go`, `core/executor.go`

Processing flow specification:

**Phase 1 - Proof Validation**:
- Extract proof components from transaction data
- Verify both signatures using validator's registered BLS public key
- Confirm block hashes differ (actual equivocation occurred)
- Check validator was in active set at proof height
- Verify proof uniqueness (not already processed)

**Phase 2 - Economic Penalty Application**:
- Calculate slash amount: 50% of validator's total stake (configurable parameter)
- Reduce validator stake in staking contract storage
- Transfer slashed amount: 10% to proof submitter (whistleblower reward), 90% to community treasury or burn address
- Update state with atomicity guarantees

**Phase 3 - Validator Set Update**:
- Remove slashed validator from active validator set immediately
- Add validator address to permanent blacklist (prevent re-staking)
- Emit state change event for network synchronization
- Schedule validator set recalculation for next epoch boundary

**Component C: Proof Gossip Protocol**

Location: `p2p/message.go`, `p2p/handlers.go`

Network propagation mechanism:

**Message Type**: `MsgSlashingProof`

**Propagation Rules**:
- Priority message type (bypass normal rate limits)
- Gossip to all connected peers immediately upon receipt
- Deduplicate based on proof hash to prevent flood
- Cache recently seen proofs (last 1000 blocks worth)
- Validate proof before further propagation

**Anti-Spam Protection**:
- Maximum 10 slashing proof messages per peer per minute
- Ban peers sending invalid proofs (reputation score penalty)
- Proof must reference recent blocks (within last 1000 blocks)

**Component D: Slashing Contract State Management**

Location: `core/system_contracts.go`

State structure in staking contract:

**State Slots**:
- Blacklist mapping: `keccak256(validator_address, "blacklist")` → boolean
- Slash history: `keccak256(validator_address, "slash_count")` → count
- Slash reason: `keccak256(validator_address, proof_hash, "reason")` → proof data
- Treasury balance: `keccak256("slashing_treasury")` → accumulated amount

**Query Interface**:
- Check if address is blacklisted (prevent stake attempts)
- Retrieve slash history for transparency
- Query treasury balance for governance decisions

#### Validation Requirements

**Functional Testing**:
1. Submit valid double-signing proof - validator must be slashed and removed
2. Submit proof for validator not in active set - must be rejected
3. Submit same proof twice - second submission must be rejected
4. Submit proof with invalid signatures - must be rejected
5. Verify slashed funds correctly distributed (submitter + treasury)
6. Confirm slashed validator cannot re-stake

**Network Testing**:
1. Verify slashing proof propagates to all peers within 1 second
2. Confirm all nodes reach consensus on slashed validator set
3. Test slashing during epoch boundary transition
4. Verify chain continues after removing validator from set

**Security Testing**:
- [ ] Proof replay attack prevention verified
- [ ] Invalid signature rejection confirmed
- [ ] State consistency across network verified
- [ ] Treasury balance arithmetic overflow checked
- [ ] Blacklist persistence across restarts confirmed

---

### 1.3 RPC Authentication and Authorization

#### Problem Statement

**Location**: `node/node.go:329-360`, `rpc/eth_api.go`

RPC server accepts connections without authentication, exposing sensitive operations to any network-accessible client.

**Current Implementation**:
```
go func() {
    fmt.Printf("RPC Server listening on %s
", addr)
    if err := http.Serve(httpListener, corsHandler); err != nil {
        // No authentication check
    }
}
```

**Impact**: Unauthorized access to node operations, potential for remote exploitation, data theft, transaction injection, state manipulation.

#### Design Solution

**Multi-Tier Authentication and Authorization System**

Implement JWT-based authentication with role-based access control (RBAC) and per-method rate limiting.

**System Architecture**:

**Component A: JWT Authentication Middleware**

Location: `rpc/auth.go` (new file)

Authentication flow specification:

**Token Structure**:
- Header: `{"alg": "HS256", "typ": "JWT"}`
- Payload: `{"sub": "client_id", "role": "admin|validator|readonly", "exp": expiration_timestamp, "iat": issued_at}`
- Signature: HMAC-SHA256 of header and payload with server secret

**Middleware Behavior**:
1. Extract Authorization header from HTTP request
2. Parse "Bearer <token>" format
3. Verify JWT signature using configured secret key
4. Check expiration timestamp (reject if expired)
5. Extract role from validated claims
6. Attach role to request context for downstream authorization
7. Reject request with HTTP 401 if any step fails

**Token Expiration Policy**:
- Admin tokens: 24 hour validity
- Validator tokens: 7 day validity with refresh
- Readonly tokens: 30 day validity
- Automatic token refresh mechanism for long-running connections

**Component B: Role-Based Access Control**

Location: `rpc/authorization.go` (new file)

Define three access levels:

**Role: "readonly"**
- Permitted methods: `eth_blockNumber`, `eth_getBalance`, `eth_getBlockByNumber`, `eth_getBlockByHash`, `eth_getTransactionByHash`, `eth_getTransactionReceipt`, `eth_call`, `eth_estimateGas`, `eth_gasPrice`, `eth_getLogs`, `net_version`, `eth_chainId`
- Restrictions: Cannot submit transactions, cannot modify state, cannot access admin APIs

**Role: "validator"**
- Inherits all readonly permissions
- Additional permissions: `eth_sendRawTransaction`, `eth_sendTransaction`, `eth_getTransactionCount`, `txpool_status`, `txpool_content`, `zelius_getValidatorInfo`
- Restrictions: Cannot access admin management functions

**Role: "admin"**
- Full access to all RPC methods
- Additional admin methods: `admin_addPeer`, `admin_removePeer`, `admin_nodeInfo`, `admin_peers`, `debug_traceTransaction`, `debug_traceBlock`, `miner_start`, `miner_stop`
- Unrestricted rate limits (separate higher tier)

**Authorization Enforcement**:
- Middleware checks role before dispatching to RPC handler
- Maintain allow-list of methods per role
- Return HTTP 403 Forbidden for unauthorized method access
- Log all authorization failures with client ID and method attempted

**Component C: Configuration Management**

Location: `node/config.go`, `cmd/zephyria/main.go`

Configuration parameters:

**Security Settings**:
- `JWTSecretPath`: File path to JWT signing secret (256-bit random key)
- `AuthEnabled`: Boolean flag to enable/disable authentication (default: true for mainnet/testnet, false for devnet)
- `TokenExpiry`: Duration map for role-based token expiration
- `AdminWhitelist`: List of IP addresses permitted for admin role (firewall layer)

**Secret Key Management**:
- Generate random 256-bit secret on first startup if not exists
- Store in secure file with 0600 permissions (owner read/write only)
- Never log or expose secret in any output
- Support rotation: accept tokens signed with either current or previous secret during rotation window

**Devnet Exception**:
- Authentication can be disabled for local development
- Emit warning banner if authentication disabled on non-localhost interface
- Automatic admin role assignment when auth disabled

**Component D: Rate Limiting Implementation**

Location: `rpc/rate_limiter.go` (new file)

Per-client rate limiting using token bucket algorithm:

**Rate Limit Tiers**:
- Readonly role: 100 requests/second, burst 200
- Validator role: 200 requests/second, burst 400
- Admin role: 1000 requests/second, burst 2000
- Unauthenticated: 10 requests/second, burst 20 (before auth failure)

**Implementation Details**:
- Use `golang.org/x/time/rate` library for token bucket limiter
- Track limits per client ID (from JWT sub claim)
- Sliding window for burst allowance
- Return HTTP 429 Too Many Requests when limit exceeded
- Include Retry-After header with backoff duration

**Cleanup Strategy**:
- Remove limiter entries for clients inactive > 1 hour
- Periodic cleanup goroutine runs every 10 minutes
- Prevents memory leak from limiter map growth

#### Validation Requirements

**Authentication Testing**:
1. Request without Authorization header - must return 401
2. Request with invalid JWT - must return 401
3. Request with expired JWT - must return 401
4. Request with valid JWT - must succeed
5. Admin IP restriction - verify non-whitelisted admin requests fail

**Authorization Testing**:
1. Readonly role attempts eth_sendTransaction - must return 403
2. Validator role accesses admin method - must return 403
3. Admin role accesses all methods - must succeed
4. Role escalation attempt via token manipulation - must fail

**Rate Limiting Testing**:
1. Send 101 requests/second with readonly token - 101st must return 429
2. Verify burst allowance permits temporary spike
3. Confirm rate limit reset after wait period
4. Test that rate limits don't affect different client IDs

**Security Checklist**:
- [ ] JWT secret stored with proper file permissions (0600)
- [ ] Secret never logged or exposed in responses
- [ ] Token expiration properly enforced
- [ ] Role-based method restrictions complete
- [ ] Rate limits prevent DoS via legitimate authentication
- [ ] Admin IP whitelist properly enforced

---

### 1.4 Reward Distribution Access Control

#### Problem Statement

**Location**: `core/system_contracts.go:160-197`

Reward distribution contract has no access control - any address can trigger reward distribution and potentially drain reward pool.

**Current Implementation**:
```
if msg.To != nil && *msg.To == rewardAddr {
    // Anyone can call this and trigger distribution!
    // No check on msg.From
}
```

**Impact**: Economic security failure, unauthorized fund drainage, inflation manipulation, consensus incentive destruction.

#### Design Solution

**Automatic Reward Distribution with Consensus Integration**

Remove externally-callable reward distribution in favor of automatic, protocol-enforced rewards during block finalization.

**System Architecture**:

**Component A: Block Finalization Reward Hook**

Location: `core/executor.go`

Integration point specification:

**Reward Distribution Trigger**:
- Execute during `ApplyBlock` after all transactions processed
- Called automatically by executor, not via external transaction
- Runs within same state transaction as block execution
- Atomic with block commit (rollback on any failure)

**Execution Flow**:
1. Complete all user transaction execution
2. Calculate cumulative gas fees collected in block
3. Determine block proposer from header coinbase field
4. Call internal reward distribution function (not exposed to transactions)
5. Update validator balances directly in state
6. Commit state with rewards included

**Component B: Reward Calculation Logic**

Location: `core/system_contracts.go`

Reward structure specification:

**Reward Components**:
- Base block reward: Fixed amount per block (e.g., 2 tokens)
- Transaction fees: Sum of all gas fees from transactions in block
- Fee distribution: 80% to block proposer, 20% to validator pool

**Validator Pool Distribution**:
- Distribute 20% of fees proportionally by stake among all active validators
- Update each validator's claimable reward balance
- Validators can claim accumulated rewards separately

**Calculation Formula**:
```
For block proposer:
  proposer_reward = base_reward + (total_gas_fees × 0.8)

For each active validator:
  validator_share = (total_gas_fees × 0.2) × (validator_stake / total_active_stake)
  validator_claimable_balance += validator_share
```

**State Updates**:
- Proposer balance increased immediately
- Validator claimable balances updated in staking contract storage
- Emit reward distribution event for transparency

**Component C: Access Control Enforcement**

Location: `core/executor.go`, `core/system_contracts.go`

Security boundaries:

**Restriction Mechanism**:
- Mark reward distribution function as internal-only (not in transaction handlers)
- Remove any transaction-based entry point to reward distribution
- If reward address receives transaction, treat as invalid operation
- Only executor during ApplyBlock can invoke distribution

**Validation Checks** (defense in depth):
- Verify call originates from executor context
- Confirm block proposer matches header coinbase
- Validate reward amounts don't exceed maximum bounds
- Check state consistency before and after distribution

**Rejected Approaches**:
- Checking `msg.From == header.Coinbase` is insufficient (can be circumvented)
- External callable rewards with access list is complex and error-prone
- Manual reward distribution requires coordination and is fragile

**Component D: Reward Claiming Mechanism**

Location: `core/system_contracts.go`

Allow validators to claim accumulated rewards:

**Claim Transaction Format**:
- Transaction to staking contract address
- Data field: `CLAIM_REWARDS` command
- From: Validator address requesting claim
- Value: 0 (claiming, not staking)

**Claim Processing**:
1. Verify sender is registered validator
2. Read claimable balance from state storage
3. Validate balance is positive
4. Transfer balance to validator's account
5. Zero out claimable balance in storage
6. Emit claim event

**State Storage**:
- Key: `keccak256(validator_address, "claimable_rewards")`
- Value: Accumulated rewards not yet claimed (uint256)

#### Validation Requirements

**Functional Testing**:
1. Produce block with transactions - verify rewards distributed automatically
2. Attempt to call reward address externally - transaction must have no effect or fail
3. Verify proposer receives base reward + 80% of fees
4. Verify validator pool receives 20% of fees distributed by stake
5. Test reward claiming by validator - balance transferred correctly

**Economic Testing**:
1. Verify total rewards match expected inflation rate
2. Confirm fee distribution adds to 100% (no loss or creation)
3. Test edge case: zero transactions (only base reward)
4. Test edge case: single validator (receives all rewards)

**Security Testing**:
- [ ] External reward distribution calls have no effect
- [ ] Reward calculations cannot overflow
- [ ] State consistency maintained if reward distribution fails
- [ ] Rewards cannot be claimed twice
- [ ] Non-validators cannot claim rewards

**Integration Testing**:
1. Multi-block sequence - verify cumulative rewards correct
2. Validator set change - verify rewards distributed to correct set
3. Slashing event - verify slashed validator stops receiving rewards
4. Claim during active validation - verify rewards still accumulate

---

### 1.5 Comprehensive Input Validation

#### Problem Statement

**Location**: Multiple RPC handlers in `rpc/eth_api.go`, `rpc/zelius_api.go`

RPC methods accept user input without comprehensive bounds checking, potentially causing resource exhaustion, crashes, or undefined behavior.

**Impact**: DoS attacks via malformed requests, node crashes, resource exhaustion, chain of exploitation from unexpected states.

#### Design Solution

**Layered Input Validation Framework**

Implement defense-in-depth validation at multiple layers with configurable limits and detailed error reporting.

**System Architecture**:

**Component A: Request Size Limits**

Location: `rpc/server.go` (HTTP layer)

Transport-level restrictions:

**HTTP Request Limits**:
- Maximum request body size: 5 MB
- Maximum request header size: 64 KB
- Maximum URL length: 4 KB
- Request timeout: 30 seconds
- Connection limit per IP: 100 concurrent

**JSON-RPC Batch Limits**:
- Maximum batch size: 100 requests per batch
- Reject batches exceeding limit with descriptive error
- Process batch requests sequentially (prevent resource spike)

**WebSocket Limits**:
- Maximum message size: 5 MB
- Maximum subscription count per connection: 10,000
- Ping/pong timeout: 60 seconds

**Component B: Parameter Validation Layer**

Location: `rpc/validation.go` (new file)

Validation utilities for common parameter types:

**Block Number Validation**:
- Accept special tags: "latest", "earliest", "pending"
- Numeric blocks: Must be >= 0 and <= current_height + 1000 (future tolerance)
- Hex format: Must be valid hex string with 0x prefix
- Error message: "invalid block number: {reason}"

**Address Validation**:
- Must be 20 bytes (40 hex characters)
- Must have 0x prefix
- Must be valid hex encoding
- Case-insensitive comparison
- Error message: "invalid address: {value}"

**Hash Validation**:
- Must be 32 bytes (64 hex characters)
- Must have 0x prefix
- Must be valid hex encoding
- Error message: "invalid hash: {value}"

**Array Size Validation**:
- Maximum addresses array: 1000 elements (for eth_getLogs address filter)
- Maximum topics array: 4 elements (EVM log topics limit)
- Maximum block range: 1000 blocks (for eth_getLogs range)
- Error message: "array exceeds maximum size: {max}"

**Component C: Method-Specific Validation**

Location: Individual RPC method implementations

Detailed validation rules per method:

**eth_getLogs Validation**:
- `fromBlock` and `toBlock` must be valid block numbers or tags
- Block range (`toBlock - fromBlock`) must not exceed 1000 blocks
- Address filter array must not exceed 1000 addresses
- Topics array must not exceed 4 elements
- Each topic can be single hash or array of hashes (max 10 per topic)

**eth_getBlockByNumber Validation**:
- Block number must be within valid range
- Full transaction boolean must be explicitly true or false
- Reject requests for very old blocks if not archive node (> 100,000 blocks old)

**eth_estimateGas Validation**:
- Gas limit in call must not exceed block gas limit
- Gas price must be >= 0
- Value must be >= 0 and <= caller balance
- Data field size must not exceed 128 KB

**eth_sendRawTransaction Validation**:
- Transaction RLP must be valid encoding
- Transaction size must not exceed 128 KB
- Signature must be valid (v, r, s values)
- Nonce must be reasonable (within +1000 of account nonce)
- Gas limit must be >= 21000 (base transaction cost)

**eth_call Validation**:
- Gas limit for call must not exceed block gas limit × 10 (simulation context)
- To address must be valid (or null for contract creation simulation)
- Block context must be valid and not too far in past

**Component D: Error Response Standardization**

Location: `rpc/errors.go` (new file)

Standardized error codes and messages:

**Error Code Categories**:
- -32700: Parse error (invalid JSON)
- -32600: Invalid request (missing required fields)
- -32601: Method not found
- -32602: Invalid params (validation failure)
- -32603: Internal error
- -32000 to -32099: Server errors (rate limit, timeout, etc.)

**Error Response Format**:
```
{
  "jsonrpc": "2.0",
  "id": <request_id>,
  "error": {
    "code": -32602,
    "message": "Invalid params",
    "data": {
      "field": "blockNumber",
      "reason": "exceeds maximum allowed value",
      "max": 1000000,
      "provided": 9999999
    }
  }
}
```

**Benefits**:
- Clear indication of what failed validation
- Actionable information for client to fix request
- Consistent error format across all methods
- Machine-parseable error details

#### Validation Requirements

**Functional Testing**:
1. Submit request with block number > current + 1000 - must reject
2. Submit eth_getLogs with 2000 block range - must reject
3. Submit transaction with 1 MB data field - must reject
4. Submit malformed address (19 bytes) - must reject
5. Submit batch with 101 requests - must reject

**Bounds Testing**:
1. Submit request at exact limit (e.g., 1000 block range) - must succeed
2. Submit request at limit + 1 - must reject
3. Test maximum values for all numeric parameters
4. Test empty arrays and null values where appropriate

**Error Message Testing**:
1. Verify error messages clearly indicate what failed
2. Confirm error codes are correct per JSON-RPC spec
3. Check that error data provides actionable information
4. Ensure sensitive information not leaked in errors

**Security Checklist**:
- [ ] All user-controlled numeric inputs validated for bounds
- [ ] All array inputs validated for size limits
- [ ] All string inputs validated for length limits
- [ ] Block range queries limited to prevent chain scan DoS
- [ ] Gas limit parameters cannot cause out-of-memory conditions
- [ ] Error messages do not reveal internal state or paths

---

## Phase 1 Completion Criteria

### Functional Requirements

| Requirement | Validation Method | Pass Criteria |
|-------------|------------------|---------------|
| No hardcoded keys in production paths | Code audit + grep search | Zero occurrences of DefaultDevKey in mainnet/testnet code |
| BLS keys not derivable from addresses | Static analysis | All BLS key usage traces back to provided keys |
| Slashing proofs verifiable and executed | Integration test | Malicious validator slashed and removed from set |
| RPC authentication enforced | Penetration test | Unauthorized requests rejected with 401/403 |
| Reward distribution automatic only | Transaction test | External calls to reward address have no effect |
| Input validation comprehensive | Fuzzing test | No crashes or resource exhaustion from malformed inputs |

### Security Requirements

- [ ] External security audit of Phase 1 changes completed
- [ ] All cryptographic operations reviewed by cryptography expert
- [ ] Penetration testing of authentication system completed
- [ ] Slashing mechanism reviewed for economic attack vectors
- [ ] Key management procedures documented and reviewed

### Documentation Requirements

- [ ] Validator setup guide with key generation instructions
- [ ] RPC authentication configuration guide
- [ ] Slashing proof submission guide for watchers
- [ ] Security incident response runbook
- [ ] Key rotation procedure documented

### Testing Requirements

- [ ] Unit tests for all new validation logic (>90% coverage)
- [ ] Integration tests for slashing across multiple nodes
- [ ] End-to-end test of validator lifecycle with proper keys
- [ ] Authentication bypass attempts documented and tested
- [ ] Chaos engineering tests (random faults during critical operations)

---

## Phase 2: Consensus Hardening (HIGH PRIORITY)

**Objective**: Ensure consensus mechanism is Byzantine fault tolerant and handles network conditions gracefully.

**Timeline**: Week 3-4 (60-80 hours)

### 2.1 Fork Choice Rule Implementation

#### Problem Statement

**Location**: Consensus package and blockchain synchronization logic

Network currently has no deterministic rule for resolving competing chain forks. When nodes receive blocks forming different chains, there's no specification for canonical chain selection.

**Impact**: Permanent network splits possible, no convergence guarantee after partition, attackers can cause forks with minimal cost.

#### Design Solution

**Multi-Criteria Fork Choice with Finality Preference**

Implement hybrid fork choice combining finality checkpoints with longest chain fallback and deterministic tiebreakers.

**Fork Choice Algorithm Specification**:

**Priority 1 - Finality-Driven Selection**:
- Each epoch boundary represents potential finality checkpoint
- Track which fork has most finalized checkpoints
- Finalized checkpoint definition: Block with quorum of validator votes (>2/3 stake)
- Prefer fork with most finalized blocks, regardless of length

**Priority 2 - Longest Chain Rule**:
- Among forks with equal finality, select longest chain
- Chain length measured in block count from genesis
- Accounts for different block production rates during partitions

**Priority 3 - Deterministic Tiebreaker**:
- If two chains have equal finality and length, select by lowest block hash at divergence point
- Ensures all honest nodes make identical choice
- Prevents flapping between equivalent forks

**Component A: Finality Checkpoint Tracking**

Location: `consensus/zelius.go`, `types/block.go`

Checkpoint structure:
- Block number (must be epoch boundary: `number % epoch_length == 0`)
- Block hash
- Aggregated vote signature from validators
- Bitmask indicating which validators signed
- Cumulative stake of signers

Checkpoint validation:
- Verify >2/3 of active stake signed
- Validate signatures against validator public keys
- Confirm checkpoint block exists and matches hash
- Ensure checkpoint builds on previous checkpoint

**Component B: Fork Choice Engine**

Location: `core/fork_choice.go` (new file)

Algorithm implementation:

**Input**: Set of competing block chains
**Output**: Single canonical chain

**Procedure**:
1. For each chain, scan for finality checkpoints
2. Count valid checkpoints per chain
3. Select chain(s) with maximum checkpoints
4. If tie, compare chain lengths (genesis to tip)
5. If still tied, compare block hashes at divergence point
6. Return chain with lowest hash

**Data Structures**:
- Chain metadata cache: Maps chain tip hash to (checkpoint_count, length, divergence_hash)
- Checkpoint validation cache: Recent checkpoint verifications (avoid re-verification)
- Fork DAG: Directed acyclic graph of block relationships for quick traversal

**Component C: Reorganization Handler**

Location: `core/blockchain.go`

Handle switching from one chain to another:

**Reorganization Procedure**:
1. Identify common ancestor of old chain and new chain
2. Unwind old chain blocks from tip to common ancestor
3. Revert state changes (apply reverse state transitions)
4. Apply new chain blocks from common ancestor to new tip
5. Update canonical block number → hash mapping
6. Update state root to new chain tip
7. Notify subscribers of reorganization event

**Safety Constraints**:
- Refuse reorg deeper than 1000 blocks (safety threshold)
- Refuse reorg crossing finalized checkpoint (finality is final)
- Validate entire new chain before discarding old chain
- Maintain old chain in database until new chain proven valid

**Component D: Network Synchronization Integration**

Location: `p2p/syncer.go`

Apply fork choice during peer synchronization:

**Sync Algorithm Enhancement**:
1. Request chain metadata from multiple peers
2. Apply fork choice rule to peer-reported chains
3. Select canonical chain per fork choice algorithm
4. Prioritize sync from peers on canonical chain
5. Request checkpoints and verification data
6. Validate checkpoints before accepting chain

**Peer Scoring**:
- Increase reputation of peers on canonical chain
- Decrease reputation of peers on abandoned forks
- Temporarily de-prioritize peers consistently on wrong fork

#### Validation Requirements

**Fork Resolution Testing**:
1. Create two competing chains with equal length - verify deterministic selection
2. Create chains with different finality - verify finalized chain preferred
3. Simulate network partition and healing - verify convergence
4. Test deep reorg rejection (beyond safety threshold)
5. Verify finalized blocks never reorganize

**Performance Testing**:
1. Benchmark fork choice with 10 competing chains - must complete <1 second
2. Test with 1000 blocks per chain - verify memory usage reasonable
3. Ensure fork choice doesn't block block production

**Security Checklist**:
- [ ] Fork choice is deterministic (same inputs always produce same output)
- [ ] Attacker cannot cause permanent fork with <1/3 stake
- [ ] Finality guarantees respected
- [ ] Reorg depth limits enforced
- [ ] Fork choice cannot be manipulated by single peer

---

### 2.2 Validator Set Synchronization

#### Problem Statement

**Location**: `consensus/zelius.go:577-661`

Validator set changes are not coordinated across network. Nodes may read validator changes from state at different times, causing consensus disagreements about who can produce blocks.

**Current Implementation**:
```
func (e *ZeliusEngine) SyncValidators(stateDB interface{}) error {
    // Reads current validators from state immediately
    // No epoch boundary enforcement
    // Changes apply instantly, causing fork risk
}
```

**Impact**: Fork risk during validator changes, leader schedule disagreements, potential for double-production if validator sets diverge.

#### Design Solution

**Epoch-Bounded Validator Set Updates**

Implement two-phase validator set updates with scheduled activation at epoch boundaries, ensuring network-wide synchronization.

**System Architecture**:

**Component A: Dual Validator Set State**

Location: `consensus/zelius.go`

Maintain two validator sets:

**Active Validator Set**:
- Currently authorized to produce blocks and vote
- Fixed for entire epoch duration
- Used for block verification and signature validation
- Cached for performance

**Pending Validator Set**:
- Validators staged for next epoch
- Updated as staking transactions occur
- Not used for current consensus decisions
- Becomes active at next epoch boundary

**State Machine**:
```
State: Current Epoch N
- Active Set: Validators from epoch N-1 transition
- Pending Set: Accumulates changes during epoch N

Event: Epoch Boundary (block number % epoch_length == 0)
- Active Set ← Pending Set (atomic swap)
- Pending Set ← copy of Active Set (new modifications start here)
- Recalculate leader schedule for new epoch
- Update cached aggregate BLS public key
```

**Component B: Staking Transaction Handling**

Location: `core/system_contracts.go`

Modify validator registration to target pending set:

**Stake Transaction Processing**:
1. Validator sends stake transaction with BLS public key
2. Executor validates transaction (sufficient stake, valid key)
3. Executor adds validator to PENDING validator set in state
4. Current epoch's active set remains unchanged
5. Change scheduled to take effect at next epoch boundary

**State Storage Layout**:
- Active set: `keccak256("active_validators")` → RLP encoded validator array
- Pending set: `keccak256("pending_validators")` → RLP encoded validator array
- Epoch number: `keccak256("current_epoch")` → uint64

**Component C: Epoch Transition Logic**

Location: `consensus/zelius.go`, `core/executor.go`

Trigger validator set update at precise moment:

**Epoch Boundary Detection**:
- Checked during block finalization
- Condition: `block_number % epoch_length == 0`
- Must occur AFTER all transactions in boundary block executed
- Must occur BEFORE next block production begins

**Transition Procedure**:
1. Read pending validator set from state
2. Validate pending set (non-empty, all have BLS keys, minimum stake)
3. Calculate total stake of pending set
4. Recalculate Byzantine fault threshold (f = (n-1)/3)
5. Atomically update active set to pending set
6. Recalculate aggregate BLS public key
7. Generate leader schedule for new epoch
8. Log transition event with validator count and total stake
9. Gossip validator set change message to network

**Component D: Network Synchronization**

Location: `p2p/sync_handlers.go`

Ensure all nodes perform transition at same block:

**Validator Set Sync Message**:
- Message type: `MsgValidatorSetUpdate`
- Contents: Epoch number, new validator set, block height
- Sent at epoch boundaries by block producers

**Verification**:
- Receiving node checks block height matches local epoch boundary
- Extracts validator set from state at that block
- Compares received set with locally computed set
- Rejects block if validator sets don't match
- Ensures all nodes agree on active validators

**Bootstrap Synchronization**:
- New nodes joining mid-epoch must learn current active set
- Request validator set for current epoch from peers
- Verify set matches state at last epoch boundary
- Cache validator set to avoid re-reading from state

#### Validation Requirements

**Functional Testing**:
1. Stake during epoch N - verify validator active in epoch N+1, not N
2. Multiple stakes in same epoch - verify all activate together
3. Unstake during epoch - verify removal at next boundary
4. Epoch boundary with zero new stakes - verify set unchanged

**Consensus Testing**:
1. Multi-node test: All nodes transition at same block height
2. Verify leader schedule agreement across all nodes post-transition
3. Test block production immediately after transition
4. Simulate node crash during transition - verify recovery

**Edge Case Testing**:
1. All validators unstake - verify epoch transition rejection or fallback
2. Single validator remains - verify consensus continues
3. Validator set doubles in size - verify performance acceptable
4. Rapid stake/unstake cycles - verify stable convergence

**Security Checklist**:
- [ ] Epoch transition is atomic (no partial updates possible)
- [ ] All nodes transition at identical block height
- [ ] Leader schedule deterministic from validator set
- [ ] Attacker cannot manipulate transition timing
- [ ] State consistency maintained across transition

---

### 2.3 Vote Pool Validation and Aggregation

#### Problem Statement

**Location**: `consensus/votepool.go`, `node/node.go:255-270`

Vote pool accepts votes without comprehensive validation, allowing duplicate votes, expired votes, and votes from non-validators.

**Impact**: Vote spamming attacks, memory exhaustion, false quorum claims, potential consensus manipulation.

#### Design Solution

**Secure Vote Pool with Comprehensive Validation**

Implement validated vote pool with duplicate detection, expiration, eligibility checking, and efficient aggregation.

**System Architecture**:

**Component A: Vote Structure Enhancement**

Location: `types/vote.go`

Enhanced vote structure:

**Vote Fields**:
- Block hash (32 bytes) - block being voted for
- Block height (8 bytes) - height of block
- Validator index (4 bytes) - position in active validator array
- Timestamp (8 bytes) - Unix timestamp of vote creation
- BLS signature (96 bytes) - validator's signature on vote message

**Vote Message Format** (signed content):
- `keccak256(block_hash || block_height || "VOTE")`
- Signature proves validator approved this specific block

**Component B: Vote Pool Data Structure**

Location: `consensus/votepool.go`

Thread-safe vote storage and tracking:

**Data Structures**:
```
VotePool:
  votes: map[BlockHash]map[ValidatorIndex]*Vote
    - Outer map: Organizes votes by block
    - Inner map: One vote per validator per block (prevents duplicates)
  
  seenVoteHashes: map[Hash]bool
    - Tracks vote message hashes for deduplication
    - Prevents replay of identical votes
  
  blockMetadata: map[BlockHash]*BlockVoteMetadata
    - firstSeen: Timestamp of first vote for block
    - cumulativeStake: Total stake of validators who voted
    - quorumReached: Boolean flag
  
  mutex: RWMutex for thread safety
```

**Metadata Tracking**:
- Track when first vote for block received (age calculation)
- Accumulate stake of voting validators
- Cache quorum calculation result
- Expire old entries automatically

**Component C: Vote Validation Pipeline**

Location: `consensus/votepool.go`

Multi-stage validation before accepting vote:

**Stage 1 - Structural Validation**:
- Verify vote has all required fields populated
- Check block hash is 32 bytes
- Check signature is 96 bytes
- Verify validator index is reasonable (< 1,000,000)

**Stage 2 - Temporal Validation**:
- Check vote timestamp is reasonable (within ±10 minutes of current time)
- Reject votes for blocks too old (>1000 blocks behind tip)
- Prevent votes for far-future blocks (>100 blocks ahead)

**Stage 3 - Eligibility Validation**:
- Verify validator index < len(active_validators)
- Confirm validator is in current active set
- Check validator not slashed or in process of unstaking

**Stage 4 - Cryptographic Validation**:
- Reconstruct vote message: `keccak256(block_hash || block_height || "VOTE")`
- Retrieve validator's BLS public key from active set
- Verify BLS signature against message and public key
- Reject if signature invalid

**Stage 5 - Duplicate Detection**:
- Compute vote hash: `keccak256(vote_signature)`
- Check if vote hash already in seenVoteHashes
- Check if validator already voted for this block
- Allow vote update if new vote has higher timestamp (vote change)

**Stage 6 - Storage and Aggregation**:
- Store vote in pool: `votes[block_hash][validator_index] = vote`
- Update cumulative stake: Add validator's stake to block metadata
- Check quorum: If cumulative_stake > (2/3 × total_active_stake), set flag
- Emit vote received event

**Component D: Vote Expiration and Cleanup**

Location: `consensus/votepool.go`

Automatic cleanup of stale votes:

**Expiration Policy**:
- Votes for blocks older than 1000 blocks are expired
- Votes for blocks not seen within 5 minutes are expired
- Cleanup runs every 30 seconds

**Cleanup Procedure**:
1. Iterate through blockMetadata entries
2. Calculate block age from firstSeen timestamp
3. If age > expiration threshold, remove all votes for block
4. Delete block entry from votes map
5. Update seenVoteHashes to remove expired vote hashes
6. Log cleanup statistics

**Memory Bounds**:
- Maximum blocks tracked: 1000 (enforced)
- Maximum votes per block: validator_count (naturally bounded)
- Maximum total votes in memory: ~100,000 (reasonable for large validator sets)

**Component E: Quorum Aggregation**

Location: `consensus/zelius.go`

Efficient vote aggregation for finality:

**Aggregation Algorithm**:
1. Retrieve all votes for block from pool: `votes[block_hash]`
2. Verify quorum reached: `blockMetadata[block_hash].quorumReached`
3. Aggregate BLS signatures: Combine all vote signatures into single signature
4. Create bitmask: Set bit for each validator who voted
5. Construct aggregated vote proof: (aggregated_signature, bitmask)
6. Include proof in next block's extra data (证明finality)

**Optimization**:
- Cache aggregated signature to avoid re-aggregation
- Incrementally update aggregation as votes arrive
- Use fast BLS aggregation (G2 signature addition)

#### Validation Requirements

**Functional Testing**:
1. Submit vote with invalid signature - must be rejected
2. Submit vote from non-validator - must be rejected
3. Submit same vote twice - second submission ignored
4. Submit vote for old block (>1000 behind) - must be rejected
5. Verify quorum detection when >2/3 stake votes

**Performance Testing**:
1. Benchmark vote validation throughput - target >10,000 votes/second
2. Test memory usage with 100 validators × 100 blocks = 10,000 votes
3. Measure cleanup overhead - should be <10ms per cleanup cycle

**Attack Resistance Testing**:
1. Spam 100,000 votes from single peer - verify rate limiting
2. Send votes with future timestamps - verify rejection
3. Replay old votes - verify deduplication
4. Send votes with invalid validator index - verify bounds checking

**Security Checklist**:
- [ ] Duplicate votes cannot inflate stake count
- [ ] Invalid signatures always rejected
- [ ] Memory usage bounded regardless of attack
- [ ] Cleanup prevents long-term memory growth
- [ ] Quorum calculation cannot be manipulated

---

### 2.4 VDF Verification Enhancement

#### Problem Statement

**Location**: `consensus/zelius.go:346`

VDF verification could be bypassed if parallel verification fails without proper fallback, and lacks replay prevention.

**Impact**: Time-based consensus security weakened, leader schedule manipulation possible, potential for VDF precomputation attacks.

#### Design Solution

**Multi-Layer VDF Verification with Replay Prevention**

Implement comprehensive VDF verification with multiple validation layers and uniqueness tracking.

**System Architecture**:

**Component A: Dual Verification Strategy**

Location: `consensus/vdf/vdf.go`

Implement both parallel and sequential verification:

**Parallel Verification** (fast path):
- Split checkpoint verification across CPU cores
- Each core verifies subset of checkpoints
- Aggregate results from all cores
- Used for normal operation (latency critical)

**Sequential Verification** (fallback):
- Single-threaded checkpoint verification
- Slower but guaranteed correct
- Used if parallel verification fails
- Enables debugging of parallel issues

**Verification Logic**:
1. Attempt parallel verification first
2. If parallel fails, immediately retry with sequential
3. If sequential also fails, reject block
4. Log disagreement between parallel and sequential (indicates bug)
5. Return verification result

**Component B: VDF Timing Validation**

Location: `consensus/zelius.go`

Prevent precomputation by validating computation time:

**Time-Based Validation**:
- VDF should take minimum time to compute based on iteration count
- Measure time between parent block and current block
- Expected VDF computation time: `iterations × time_per_iteration`
- Reject block if timestamp too close to parent (VDF "too fast")

**Timing Thresholds**:
- Minimum time: `(iterations / hardware_benchmark_rate) × 0.8` (allow 20% margin for faster hardware)
- Maximum time: No upper limit (validators may be slow, that's okay)
- Benchmark rate: Determined by reference implementation (e.g., 1M iterations/second)

**Validation Logic**:
```
parent_time = parent_block.timestamp
current_time = current_block.timestamp
time_delta = current_time - parent_time

expected_vdf_time = iterations / benchmark_rate
minimum_time = expected_vdf_time × 0.8

if time_delta < minimum_time:
    reject block ("VDF computed too quickly, possible precomputation")
```

**Component C: VDF Uniqueness Tracking**

Location: `consensus/zelius.go`

Prevent VDF replay attacks:

**Replay Prevention**:
- Track recently seen VDF outputs in cache
- Cache size: Last 10,000 VDF outputs (covers ~100 epochs)
- Storage: `map[VDFOutputHash]bool`
- Check new VDF output against cache before acceptance

**Implementation**:
```
VDF Verification Enhancement:
1. Extract final VDF checkpoint from block
2. Compute hash of VDF output: keccak256(final_checkpoint)
3. Check if hash exists in seenVDFs cache
4. If found: Reject block (replay attack detected)
5. If not found: Continue verification, add to cache
6. Periodically trim cache (keep last 10,000 entries)
```

**Cache Management**:
- LRU eviction policy (least recently used removed first)
- Thread-safe access with read-write mutex
- Persistence optional (can rebuild on restart)

**Component D: Checkpoint Integrity Validation**

Location: `consensus/vdf/vdf.go`

Validate entire VDF chain structure:

**Checkpoint Chain Validation**:
- Each checkpoint must be hash of previous checkpoint + iteration
- First checkpoint derives from parent block's final checkpoint
- All intermediate checkpoints must be present (no gaps)
- Checkpoint count must match expected count (iterations / interval)

**Validation Procedure**:
```
For each checkpoint i from 0 to (iterations / interval):
  1. Retrieve checkpoint[i] from block extra data
  2. If i == 0:
       input = parent_block.final_checkpoint
     else:
       input = checkpoint[i-1]
  3. Compute expected: Hash(input)^(interval) mod p
  4. Verify checkpoint[i] == expected
  5. If mismatch: Reject block
```

**Component E: VDF Failure Handling**

Location: `consensus/zelius.go`

Graceful handling of verification failures:

**Error Classification**:
- **Invalid VDF**: VDF verification failed (cryptographic check)
- **Replay VDF**: VDF output seen before
- **Fast VDF**: Block timestamp too soon after parent
- **Missing VDF**: VDF data absent or truncated

**Response Strategy**:
- Invalid/Replay/Fast VDF: Reject block immediately, ban peer (reputation penalty)
- Missing VDF: Request block again (may be network corruption)
- Log all VDF failures with details for analysis

**Metrics Collection**:
- Count VDF verifications (success/failure)
- Track verification latency (parallel vs sequential)
- Monitor cache hit rate on replay check
- Alert if failure rate exceeds threshold (0.1%)

#### Validation Requirements

**Functional Testing**:
1. Submit block with invalid VDF - must be rejected
2. Submit block with replayed VDF from old block - must be rejected
3. Submit block with timestamp too soon after parent - must be rejected
4. Submit valid block - parallel and sequential verification agree
5. Verify checkpoint chain integrity validation

**Performance Testing**:
1. Benchmark parallel verification - should be <50ms for typical iteration count
2. Benchmark sequential verification - establish baseline for comparison
3. Test cache lookup performance - should be <1μs per lookup

**Attack Resistance Testing**:
1. Attempt to replay VDF from 100 blocks ago - verify rejection
2. Submit block with parent timestamp + 1ms - verify rejection for fast VDF
3. Submit block with partial VDF checkpoints - verify rejection
4. Test with invalid checkpoint in middle of chain - verify detection

**Security Checklist**:
- [ ] VDF replay impossible due to uniqueness tracking
- [ ] Precomputation attack prevented by timing validation
- [ ] Parallel verification failure triggers sequential fallback
- [ ] Cache size bounded (no memory exhaustion)
- [ ] All checkpoint chain links validated

---

### 2.5 Randomness Enhancement

#### Problem Statement

**Location**: `consensus/zelius.go:523-526`

Leader selection randomness is predictable once VDF is computed, enabling targeted DoS attacks on future leaders.

**Current Implementation**:
```
seedInput := append(e.CurrentEpochSeed.Bytes(), new(big.Int).SetUint64(view).Bytes()...)
seed := crypto.Keccak256Hash(seedInput)
```

**Impact**: Leader schedule entirely predictable, targeted DoS attacks on future leaders, MEV manipulation opportunities.

#### Design Solution

**Multi-Source Entropy Mixing**

Combine VDF output with VRF randomness and chain state to create unpredictable leader selection.

**System Architecture**:

**Component A: VRF Integration**

Location: `consensus/zelius.go`

Add Verifiable Random Function output to entropy mix:

**VRF Structure**:
- Each block producer generates VRF output using their BLS private key
- VRF input: `epoch_seed || block_height`
- VRF output: 32-byte random value + 96-byte proof
- VRF proves randomness without revealing private key

**VRF Generation**:
```
During block sealing:
1. Compute VRF input: keccak256(epoch_seed || block_number)
2. Generate VRF output using BLS private key: VRF.Prove(sk, input)
3. Store VRF output + proof in block ExtraData
4. VRF output contributes to next block's leader selection
```

**VRF Verification**:
```
During block verification:
1. Extract VRF output and proof from ExtraData
2. Retrieve block producer's BLS public key
3. Verify VRF proof: VRF.Verify(pk, input, output, proof)
4. Reject block if VRF proof invalid
5. Accept VRF output as valid randomness contribution
```

**Component B: Multi-Source Entropy Mixer**

Location: `consensus/zelius.go`

Combine multiple entropy sources:

**Entropy Sources**:
1. **VDF Output**: From Proof-of-History chain (verifiable, sequential)
2. **VRF Output**: From previous block producer (unpredictable until block sealed)
3. **Parent Block Hash**: From blockchain state (includes transaction ordering)
4. **Block Timestamp**: From proposer (limited manipulation possible)

**Mixing Algorithm**:
```
Input: epoch_seed, view_number, parent_block
Output: leader_selection_seed

Procedure:
1. Extract VRF output from parent block ExtraData
2. Extract final VDF checkpoint from parent block
3. Concatenate sources: vdf_output || vrf_output || parent_hash || timestamp
4. Hash combination: keccak256(concatenated_sources || view_number)
5. Return hash as leader selection seed
```

**Security Properties**:
- Unpredictable: VRF output unknown until block sealed
- Verifiable: All components cryptographically verified
- Non-manipulable: Producer cannot bias output without detection

**Component C: Weighted Leader Selection**

Location: `consensus/zelius.go`

Select leader based on stake-weighted randomness:

**Selection Algorithm**:
```
Input: selection_seed, validator_set
Output: selected_leader

Procedure:
1. Calculate total active stake: sum(validator_i.stake for all validators)
2. Convert seed to integer: seed_int = BigInt(selection_seed)
3. Compute target: target = seed_int mod total_stake
4. Iterate validators in deterministic order (sorted by address):
     cumulative_stake = 0
     for validator in sorted(validator_set):
         cumulative_stake += validator.stake
         if cumulative_stake > target:
             return validator as leader
```

**Fairness Properties**:
- Probability of selection proportional to stake
- Deterministic given seed and validator set
- All nodes compute identical result

**Component D: Unpredictability Analysis**

Location: Documentation and testing

Quantify unpredictability improvement:

**Predictability Timeline**:
- **Old System**: Leader schedule predictable entire epoch in advance (after VDF computed)
- **New System**: Next leader unpredictable until current block sealed (VRF reveals randomness)

**Attack Difficulty**:
- **Old System**: Attacker knows future leaders, can prepare targeted attacks days in advance
- **New System**: Attacker learns next leader only seconds before their slot, insufficient time for targeted setup

**DoS Mitigation**:
- Short prediction window limits effectiveness of leader-targeted DoS
- Attacker must maintain persistent attack rather than timed strike
- Increases cost of DoS attack significantly

#### Validation Requirements

**Functional Testing**:
1. Generate 1000 blocks - verify VRF present in each block
2. Verify VRF proof validates correctly for each block
3. Verify leader selection differs when VRF output differs
4. Confirm leader selection deterministic given same inputs
5. Test stake-weighted selection distribution over 10,000 blocks

**Randomness Quality Testing**:
1. Statistical analysis of leader selection - verify uniform distribution adjusted for stake
2. Chi-squared test for randomness of VRF outputs
3. Autocorrelation test - verify no patterns in leader sequence
4. Verify mixing function produces uniform distribution

**Security Testing**:
1. Attempt to submit block with invalid VRF proof - verify rejection
2. Attempt to manipulate VRF output - verify detection
3. Analyze predictability window - confirm <block_time (e.g., <500ms)
4. Test with malicious validator attempting to bias output

**Performance Testing**:
1. Benchmark VRF generation overhead - should be <5ms
2. Benchmark VRF verification overhead - should be <10ms
3. Verify leader selection computation <1ms
4. Confirm entropy mixing doesn't slow block verification

**Security Checklist**:
- [ ] VRF output unpredictable before block sealed
- [ ] VRF proof verification prevents manipulation
- [ ] Leader selection deterministic and verifiable
- [ ] No correlation between consecutive leader selections
- [ ] Stake-weighting correctly implemented

---

## Phase 2 Completion Criteria

### Consensus Requirements

| Requirement | Validation Method | Pass Criteria |
|-------------|------------------|---------------|
| Fork choice deterministic | Multi-node test with competing chains | All nodes converge to same canonical chain |
| Validator set sync coordinated | Epoch transition test across nodes | All nodes have identical active set post-transition |
| Vote pool prevents duplicates | Spam test with duplicate votes | Memory usage remains bounded |
| VDF replay prevented | Replay attack test | All replayed VDFs rejected |
| Randomness unpredictable | Statistical analysis | Leader selection passes randomness tests |

### Network Resilience Requirements

- [ ] Network withstands 33% Byzantine validators
- [ ] Consensus continues through network partition and healing
- [ ] Fork choice handles 10+ competing chains efficiently
- [ ] Validator transitions occur without missed blocks

### Documentation Requirements

- [ ] Fork choice algorithm specification documented
- [ ] Epoch transition procedure documented for validators
- [ ] VDF security properties explained
- [ ] Randomness sources and mixing documented

### Testing Requirements

- [ ] Multi-node integration tests for all consensus mechanisms
- [ ] Byzantine behavior simulation tests
- [ ] Network partition chaos engineering tests
- [ ] Performance benchmarks under load (>5000 TPS)

---

## Phase 3: State Management & Persistence (HIGH PRIORITY)

**Objective**: Ensure long-term state sustainability, data integrity, and efficient state access.

**Timeline**: Week 5-6 (50-70 hours)

### 3.1 State Pruning System

#### Problem Statement

**Location**: `state/statedb.go:318-355`

State commits never prune old versions, causing database to grow indefinitely.

**Impact**: Disk space exhaustion, performance degradation, impossible to run full nodes on consumer hardware long-term.

#### Design Solution

**Versioned State with Automatic Pruning**

Implement versioned state storage with configurable retention and automatic pruning of old versions.

**System Architecture**:

**Component A: State Versioning Layer**

Location: `state/statedb.go`

Add version tracking to state storage:

**Versioning Scheme**:
- Each state commit assigned monotonically increasing version number
- Version number corresponds to block height
- State keys prefixed with version: `v{version}:{key}`
- Allows multiple historical state versions to coexist

**Storage Format**:
```
Key Format: v{block_height}:{state_key}
Value Format: RLP(state_value)

Example:
  v1000:account_0xABCD...  → RLP(balance, nonce, code_hash, root)
  v1001:account_0xABCD...  → RLP(updated_balance, nonce, code_hash, root)
```

**Component B: Retention Policy Configuration**

Location: `node/config.go`

Configurable pruning parameters:

**Configuration Parameters**:
- `StateRetentionBlocks`: Number of recent blocks to retain (default: 1000)
- `PruneInterval`: Frequency of pruning runs (default: every 1000 blocks)
- `ArchiveMode`: Boolean to disable pruning entirely (archive nodes)
- `PruningParallelism`: Number of goroutines for pruning (default: 4)

**Retention Modes**:
- **Full Archive**: Retain all state versions forever (no pruning)
- **Recent History**: Retain last N blocks (default N=1000)
- **Minimal**: Retain only last 100 blocks (aggressive pruning)

**Component C: Pruning Algorithm**

Location: `state/pruning.go` (new file)

Efficient old state removal:

**Pruning Procedure**:
```
Input: current_block_height, retention_blocks
Output: pruned_state_count

Procedure:
1. Calculate prune_before = current_block_height - retention_blocks
2. Iterate database keys with version prefix
3. For each key matching pattern v{version}:*
     Parse version number from key
     If version < prune_before:
         Delete key from database
         Increment pruned_count
4. Batch deletions for efficiency (delete 1000 keys per batch)
5. Return pruned_count
```

**Optimization Strategies**:
- Use database range deletion for efficiency (delete v0:* to v{prune_before}:*)
- Run pruning in background goroutine (non-blocking)
- Rate limit deletions to prevent I/O saturation
- Checkpoint progress to resume if interrupted

**Component D: Pruning Trigger Mechanism**

Location: `core/blockchain.go`

Automatic pruning invocation:

**Trigger Conditions**:
- Every N blocks (e.g., every 1000 blocks)
- Triggered after block commit completes
- Asynchronous execution (doesn't block blockchain progress)

**Implementation**:
```
After block commit:
1. Check if block_height % prune_interval == 0
2. If yes:
     Launch background goroutine:
       Call pruning.Prune(current_height, retention_blocks)
       Log pruning statistics (keys deleted, time taken)
       Update metrics (disk space reclaimed)
```

**Safety Mechanisms**:
- Never prune state for blocks in last retention_blocks window
- Never prune if current blockchain tip references that state
- Verify state root still accessible after pruning (integrity check)

**Component E: State Resurrection Protection**

Location: `state/statedb.go`

Prevent errors when accessing pruned state:

**Access Handling**:
- Queries for state at pruned block heights return clear error
- Error message indicates state pruned and suggests archive node
- Recent state (within retention window) always accessible

**State Query API**:
```
func StateAt(root common.Hash) (*StateDB, error)

Returns:
- State object if root within retention window
- Specific error if root pruned: ErrStatePruned
