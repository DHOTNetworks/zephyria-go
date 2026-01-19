# Zephyria: High-Performance Zig Node & JoyBoy VM

Zephyria is a state-of-the-art Ethereum-compatible blockchain client implemented in Zig, designed for extreme throughput and low-latency execution. At its core is the **JoyBoy VM**, a custom registers-based JIT execution engine capable of reaching 200k+ TPS.

---

## 🚀 Key Architectural Features

### 1. JoyBoy VM (EVM JIT Engine)
JoyBoy is a multi-tiered execution engine that moves beyond traditional interpreter bottlenecks:

*   **Copy-and-Patch JIT (Stencil Engine)**: A highly portable and fast JIT strategy. It utilizes pre-compiled machine code templates (stencils) that are linked and patched at runtime with dynamic literals and jump targets. This minimizes compilation overhead while providing near-native execution speed.
*   **Native Register JIT (ARM64)**: An advanced execution tier that performs register allocation. It maps the EVM's virtual stack directly onto physical ARM64 register banks (using 4x64-bit registers for u256 limbs), significantly reducing memory operations and stack traffic.
*   **Soft-MMU & Sandboxing**: Implements a virtualized memory management unit with a 4GB isolated heap per EVM instance. It uses `mmap` for zero-cost isolation and `mprotect` to enforce SFI (Software Fault Isolation) boundaries.
*   **Static Verifier**: A pre-flight analysis pass that builds a Control Flow Graph (CFG), checks JUMPDEST validity, and ensures stack safety before any code enters the JIT pipeline.

### 2. High-Throughput Node Architecture
The node surrounding the VM is built for massive parallelism and efficient state management:

*   **TigerStyle LSM Storage**: A custom Log-Structured Merge (LSM) tree engine inspired by TigerBeetle. It features a Write-Ahead Log (WAL), a high-concurrency MemTable, and multi-layered SSTables optimized for NVMe throughput.
*   **Verkle Trie Integration**: Implements Ethereum's future state-storage standard. Verkle Tries use vector commitments (via the Banderwagon curve) to reduce witness sizes, enabling stateless-client functionality.
*   **Deterministic Parallel Scheduler**: A wave-based scheduler that performs static dependency analysis over account access lists. It builds a conflict graph and executes independent transactions in parallel across CPU cores using a work-stealing thread pool.
*   **Low-Latency Networking**: A dedicated P2P stack using the QUIC protocol for reliable, multiplexed communication between nodes.

---

## 📂 Project Structure

- `src/vm/joyboy`: The register-allocated Native JIT implementation.
- `src/vm/stencils`: Binary machine code stencils for the Copy-and-Patch JIT.
- `src/vm/opcodes`: Individual opcode implementations for both JIT and Interpreter tiers.
- `src/storage/lsm`: The custom LSM-tree database engine.
- `src/storage/verkle`: Verkle trie implementation and cryptographic primitives.
- `src/consensus`: Beacon chain logic and fork choice rules.
- `src/p2p`: QUIC-based peer-to-peer networking.
- `src/rpc`: High-performance JSON-RPC implementation over HTTP and gRPC.

---

## 🛠 Build & Development

### Prerequisites
- **Zig 0.15.2** (or latest master)
- **ARM64 hardware** (recommended for Native JIT tier)

### Build Instructions
```bash
# Build the production node
zig build -Doptimize=ReleaseFast

# Run performance benchmarks
zig build run-benchmark
```

### Testing
```bash
# Run all tests (Unit + EVM Spec Tests)
zig build test --summary all
```

---

## 📈 Performance Targets
- **Single-core JIT**: 20k - 50k TPS (complex contracts)
- **Multi-core Parallel**: 200k+ TPS (simple transfers/ERC20)
- **Storage Latency**: < 10μs per state access (MemTable hit)
