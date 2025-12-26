# Zephyria Blockchain

![Status](https://img.shields.io/badge/status-active-success.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Go Version](https://img.shields.io/badge/go-1.21%2B-blue)

**Zephyria** is a high-performance, EVM-compatible blockchain engine built for speed, scalability, and low latency. It is designed to process thousands of transactions per second with instant finality, making it an ideal foundation for next-generation decentralized applications.

---

## 🚀 What is Zephyria?

Zephyria is a Layer-1 blockchain implementation written in Go. It distinguishes itself by using a custom consensus engine named **Zelius**, which combines the robustness of HoneyBadger BFT with the deterministic leader scheduling found in high-throughput chains like Solana.

**Key capabilities:**
- **EVM Compatibility**: Deploys existing Ethereum smart contracts without modification.
- **Instant Finality**: Blocks are finalized immediately upon mining.
- **High Throughput**: Capable of 3,000+ TPS in optimized environments.

---

## ⚙️ How It Works

The Zephyria architecture is modular, separating concerns into distinct subsystems to ensure stability and performance:

### 1. The Core (Node Service)
Acts as the central motherboard, orchestrating communication between the database, P2P network, and consensus engine. It manages the main event loop for block processing.

### 2. Consensus: Zelius
Zelius is a **Proof-of-Stake (PoS)** consensus mechanism that uses a **Deterministic Leader Schedule**.
- **Efficiency**: Leaders are known in advance for each epoch, allowing for "pipelined" block production.
- **Fairness**: Uses weighted randomness based on stake size to select block proposers.
- **Security**: Validators sign blocks with ECDSA keys; double-signing leads to slashing.

### 3. State Management
Zephyria uses a hybrid approach for state storage:
- **Verkle Tries**: For efficient, stateless-friendly account storage.
- **LevelDB**: For persistent on-disk storage of blocks and state headers.
- **Pre-fetching**: Predictive loading of state data to minimize execution latency.

---

## ⚡ What It Offers

Compared to traditional blockchain implementations, Zephyria offers:

- **Dynamic Block Times**: Generally sub-second block times (~200ms - 500ms).
- **Execution Pipelining**: Decouples execution, sealing, and committing to maximize CPU usage.
- **Stake-Gated Networking**: Priority P2P access for active validators, protecting the network from spam.
- **Developer Friendly**: Fully compatible with Metamask, Hardhat, and Foundry via standard JSON-RPC.

---

## 📊 Performance Stats

Internal benchmarks (Devnet Mode, Single Node on M1/M2 hardware) show:

| Metric | Performance |
| :--- | :--- |
| **Throughput (TPS)** | **3,000 - 5,000 TPS** |
| **Block Time** | **200ms - 500ms** |
| **Time to Finality** | **< 500ms (Instant)** |
| **Startup Time** | **< 2 seconds** |

> *Note: Real-world performance may vary based on network latency and geographical distribution of nodes.*

---

## 📦 How to Use

### Prerequisites
- **Go 1.21+** installed.
- **Make** (optional, for build commands).

### 1. Installation

Clone the repository and build the binaries:

```bash
git clone https://github.com/0xZephyria/Zephyria.git
cd Zephyria
make build
```

This will create two binaries in your root directory:
- `zephyria`: The main node client.
- `zephyria-bench`: A benchmarking tool for stress testing.

### 2. Running a Node

To start a node with default devnet settings:

```bash
./zephyria
```

### 3. Connecting to the Node

Once running, the node exposes two ports:
- **JSON-RPC (Port 8545)**: Connect your wallet (e.g., Metamask) or run scripts.
  - RPC URL: `http://localhost:8545`
  - Chain ID: `1337`
- **P2P (Port 30303)**: For peering with other nodes.

### 4. Running Benchmarks

To test the performance on your machine:

```bash
./zephyria-bench
```

This will flood the node with transactions and report the real-time TPS and block processing times.

---

## 🤝 Contributing

Contributions are welcome! Please check `ARCHITECTURE.md` to understand the system design before submitting a Pull Request.

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.
