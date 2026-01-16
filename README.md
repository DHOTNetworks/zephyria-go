# Zephyria Zig Node

This is the standalone implementation of the Zephyria Node in Zig.

## Structure

The project is structured into the following modules:
- `src/storage`: NOMT implementation, LSM tree logic.
- `src/vm`: Just-In-Time (JIT) EVM implementation using `zasm`.
- `src/consensus`: Consensus logic (Beacon Chain, Fork Choice).
- `src/p2p`: Networking stack using `libp2p` and `QUIC`.
- `src/rpc`: JSON-RPC server.

## Dependencies

The project uses the following dependencies (managed via `build.zig.zon`):
- `zasm`: For JIT compilation.
- `zig-libp2p`: For P2P networking.
- `zig-msquic`: For QUIC support.
- `zig-eth-secp256k1`: For ECDSA signatures.
- `blst`: For BLS12-381 signatures.
- `kzigg`: For KZG commitments (EIP-4844).
- `ssz`: For SSZ serialization.
- `rlp`: For RLP serialization.

## Build Instructions

### Prerequisites
- Zig (latest version, currently 0.15.2 was used during setup)

### Building
To build the project:
```bash
zig build
```

### Known Issues
As of Jan 2026, the `zig` ecosystem is evolving rapidly. The dependencies fetched might be using older Zig build APIs (e.g., `std.build.Builder`) which are incompatible with Zig 0.15.2.
If you encounter `root source file struct 'std' has no member named 'build'` errors, this indicates that the dependencies need to be updated or you may need to use an older Zig version (e.g., 0.13.0 or 0.14.0) that matches the dependencies' expectations.
