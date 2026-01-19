## Native VM Production Readiness Plan

### Scope
- **Goal**: Bring the Zig native, register-based EVM (native JIT) and surrounding VM infrastructure to **production-grade correctness, security, and throughput**, targeting **200k+ TPS** for simple transactions under realistic multi-core hardware.
- **Focus of this document**: What is already present in `src/vm`, and **concrete pending work** for:
  - **Functional completeness & spec adherence**
  - **Performance & throughput (micro + macro level)**
  - **Security & determinism**
  - **Testing & observability**

### 1. Current VM State (Snapshot from `src/vm`)
- **Execution engines**
  - **Stencil JIT**: [JitCompiler](file:///Users/karan/zephyria/zig/src/vm/jit_compiler.zig) with stencil-based codegen, used via `engine_type = .stencil_jit` in [EVM](file:///Users/karan/zephyria/zig/src/vm/main.zig).
  - **Native register JIT**: [NativeJitCompiler](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig) implementing a **register-allocated ARM64 JIT** over a virtual stack mapped to register banks.
  - **Execution entry**: [EVM.execute](file:///Users/karan/zephyria/zig/src/vm/main.zig) chooses JIT first, falls back to interpreter on error.

- **Core VM components**
  - **Memory**: Soft-MMU design in [memory.zig](file:///Users/karan/zephyria/zig/src/vm/memory.zig) reserving 4GB with `mmap`, committing on demand via `mprotect`, and exposing `ensureCapacity`, `store`, `load`, etc.
  - **Stack**: Simple bounded stack (1024 items) in [stack.zig](file:///Users/karan/zephyria/zig/src/vm/stack.zig) using `ArrayListUnmanaged(BigInt)`.
  - **Call frames / call stack**: [call_frame.zig](file:///Users/karan/zephyria/zig/src/vm/call_frame.zig) with `CallFrame`, `CallStack`, call gas helpers and basic tests.
  - **Verifier skeleton**: [Verifier](file:///Users/karan/zephyria/zig/src/vm/verifier.zig) building a CFG over basic blocks, with stack effect model and JUMPDEST tracking (but stack effect not fully wired yet).
  - **Parallel execution infrastructure**: [parallel_optimized.zig](file:///Users/karan/zephyria/zig/src/vm/parallel_optimized.zig) provides:
    - Work-stealing thread pool
    - Optimized dependency analyzer over accounts & access lists
    - Wave-based parallel scheduler and TPS benchmarks.

- **Opcode layer**
  - Opcode enum and gas table in [main.zig](file:///Users/karan/zephyria/zig/src/vm/main.zig) (`Opcode`, `getGasCost`).
  - Per-opcode interpreter implementations in `opcodes/*.zig`, plus JIT integration via `jit_compile` functions using [CompilerInterface](file:///Users/karan/zephyria/zig/src/vm/compiler_interface.zig).
  - Many opcodes have **JIT stubs** returning `error.UnsupportedOpcode` (see `grep UnsupportedOpcode` across `opcodes/`).

- **Benchmarks & tests**
  - Native JIT TPS benchmark in [tests/benchmark_tps.zig](file:///Users/karan/zephyria/zig/src/vm/tests/benchmark_tps.zig) measuring init, compile, and full execution.
  - Parallel deterministic tests in [test_parallel_jit_deterministic.zig](file:///Users/karan/zephyria/zig/src/vm/tests/test_parallel_jit_deterministic.zig).
  - Basic native VM tests in [test_native_vm.zig](file:///Users/karan/zephyria/zig/src/vm/tests/test_native_vm.zig).

---

### 2. Pending Functional Implementations (Correctness & Completeness)

#### 2.1 Native JIT (Register VM) gaps
- **u256 division & remainder**
  - **Current state**: [emit_native_div](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig) and [emit_native_rem](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig) return `error.UnsupportedByNative` with a TODO comment referencing Knuth division.
  - **Pending work**:
    - Implement **correct u256 DIV/SDIV/MOD/SMOD/MODREM** using a robust multi-limb division algorithm (Knuth D or Barrett/Montgomery style), carefully mapping to ARM64 integer ops.
    - Validate behavior for all edge cases (division by zero, negative signed division, overflow semantics) against the Yellow Paper and reference clients.

- **Register spilling and bank allocation**
  - **Current state**: `NUM_BANKS = 3` in [NativeJitCompiler](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig), mapping 3×4 64-bit registers. [allocate_bank](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig#L1008-L1016) returns `error.TODO_RegisterSpilling` if all banks are in use.
  - **Pending work**:
    - Implement **spilling to the EVM stack or shadow stack** when banks are exhausted, including:
      - Spill selection policy (e.g. simple LRU, or depth-based heuristic).
      - Emitting store/load sequences to/from `[x19 + offset]` coordinating with `virtual_stack` metadata.
    - Ensure **correct liveness tracking** so spilled values are reloaded only when necessary and dead values free banks.
    - Stress-test with deep stack usage (close to 1024 items) and many DUP/SWAP patterns.

- **Constant loading limitations**
  - **Current state**: [emit_load_constant](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig#L1025-L1030) rejects values `> 0xFFFF` via `error.TODO_LargeConstants`.
  - **Pending work**:
    - Implement **generic u256 constant loading**, e.g. by decomposing into 64-bit limbs and reusing [emit_load_u64](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig#L521-L533) across the 4-bank layout.
    - Optimize hot cases: 0, 1, small immediates, and power-of-two masks.
    - Add constant pooling / deduplication if code size becomes a concern.

- **Conditional branch correctness (JUMPI)**
  - **Current state**: [compile_jumpi](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig#L326-L353) uses a single limb via `CBNZ` on the **least significant 64 bits**; TODO comment notes this is not a full 256-bit check.
  - **Pending work**:
    - Implement correct `ISZERO` / non-zero semantics for **entire 256-bit value**, by OR-ing all limbs into a scratch register before branching or by reusing the `emit_native_iszero` scheme.
    - Ensure that **JUMPI** consumes the condition from the virtual stack in the correct order and matches interpreter semantics in all cases.

- **Memory expansion semantics for native MLOAD/MSTORE**
  - **Current state**: Native MLOAD/MSTORE in [native_compiler.zig](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig#L940-L1004) enforce bounds based on `ctx.memory_len`, with a fast path and a “zero on OOB” / no-op path.
  - **Pending work**:
    - Align **memory expansion semantics with the interpreter** and Yellow Paper:
      - Correctly charge gas based on new highest accessed memory word (including quadratic component).
      - Ensure out-of-range accesses **trigger memory expansion** where required, not silently zero/ignore unless that is explicitly consistent with EVM.
    - Harmonize behavior between stencils ([stencils/memory.zig](file:///Users/karan/zephyria/zig/src/vm/stencils/memory.zig)) and native paths.

- **Stencil slow-path memory expansion**
  - **Current state**: [stencil_mstore](file:///Users/karan/zephyria/zig/src/vm/stencils/memory.zig#L28-L48) notes `// Slow Path: Partial write (TODO: Should trigger memory expansion)`.
  - **Pending work**:
    - Implement **slow-path memory growth** for partial writes and reads, keeping SFI guarantees.
    - Ensure gas for memory expansion is charged consistently in both JIT and interpreter.

#### 2.2 Opcode coverage and JIT support
- **Interpreter vs JIT parity**
  - **Current state**:
    - Interpreter in [executeInterpreted](file:///Users/karan/zephyria/zig/src/vm/main.zig#L494-L508) executes all registered opcodes.
    - Many `opcodes/*.zig` implement `execute` but have `jit_compile` stubs returning `error.UnsupportedOpcode` (e.g. CALL, CREATE, CREATE2, STATICCALL, DELEGATECALL, LOGx, various environment opcodes).
  - **Pending work**:
    - For **all opcodes in `Opcode` enum**, implement **JIT backends** (either stencil or native) or provide a **hybrid fallback** (e.g. interpret only those instructions but remain in JITed loop).
    - Critical missing JIT support categories:
      - **External calls**: CALL, CALLCODE, DELEGATECALL, STATICCALL ([call.zig](file:///Users/karan/zephyria/zig/src/vm/opcodes/call.zig), [delegatecall.zig](file:///Users/karan/zephyria/zig/src/vm/opcodes/delegatecall.zig), [staticcall.zig](file:///Users/karan/zephyria/zig/src/vm/opcodes/staticcall.zig), [callcode.zig](file:///Users/karan/zephyria/zig/src/vm/opcodes/callcode.zig)).
      - **Contract creation**: CREATE, CREATE2 ([create.zig](file:///Users/karan/zephyria/zig/src/vm/opcodes/create.zig), [create2.zig](file:///Users/karan/zephyria/zig/src/vm/opcodes/create2.zig)).
      - **Environment / block opcodes**: BLOCKHASH, GASPRICE, GASLIMIT, CHAINID, COINBASE, BASEFEE, etc.
      - **LOG0–LOG4**, **EXTCODE* family**, **EXP**, **SHA3** dynamic gas paths, and **BALANCE**.
    - Ensure JIT and interpreter produce **bit-identical results and gas usage** for every opcode, across all corner cases.

- **EVM spec coverage (hard forks & EIPs)**
  - **Pending work**:
    - Audit opcodes and gas tables against the **latest mainnet fork** (Shanghai/Cancun and beyond) and adjust:
      - Gas costs (e.g. SLOAD/SSTORE under EIP-2929/2200, warm vs cold costs).
      - Newly introduced or repurposed opcodes, if any future forks are in scope.
    - Define a **fork configuration layer** that can parameterize gas costs and semantics per chain/fork, rather than hardcoding a single configuration in `getGasCost`.

#### 2.3 Verifier & static analysis
- **Stack effect integration**
  - **Current state**:
    - [Verifier.buildCFG](file:///Users/karan/zephyria/zig/src/vm/verifier.zig#L89-L165) currently uses `StackEffect{ .pops = 0, .pushes = 0 }` instead of calling [getStackEffect](file:///Users/karan/zephyria/zig/src/vm/verifier.zig#L212-L271).
    - `getStackEffect` has partial coverage over opcodes but does not yet cover every instruction (e.g. some environment/log/storage variants).
  - **Pending work**:
    - Wire **real stack effects** into CFG building, and extend `getStackEffect` to fully cover all opcodes.
    - Enforce stack underflow/overflow constraints **statically** before JIT or interpretation.

- **Jump destination and control-flow safety**
  - **Current state**:
    - Verifier marks JUMPDESTs and ensures basic block boundaries, but does not yet validate **all possible jump targets** or detect infinite loops robustly.
  - **Pending work**:
    - Check that every dynamic `JUMP`/`JUMPI` target is a **valid, reachable JUMPDEST**.
    - Provide a **stronger liveness/termination heuristic**, or at least more thorough unreachable-code detection.
    - Integrate verifier runs into the **JIT compilation path** to reject malformed or dangerous bytecode up front.

#### 2.4 Gas accounting and economic correctness
- **Gas model alignment**
  - **Current state**:
    - `getGasCost` in [main.zig](file:///Users/karan/zephyria/zig/src/vm/main.zig#L342-L389) provides a simplified static gas table.
    - Dynamic gas (e.g. for SHA3, EXP, memory expansion, SSTORE transitions) is partially handled in individual opcode files but needs a full audit.
  - **Pending work**:
    - Implement **full EVM gas semantics**, including:
      - **Memory expansion gas**: quadratic cost based on highest accessed memory offset.
      - **SHA3 gas** proportional to word length.
      - **EXP gas** proportional to exponent size.
      - **SSTORE** gas and **refund** rules per EIP-2200/2929 (zero→non-zero, non-zero→zero, warm/cold).
      - **CALL family** gas rules (stipend, forwarded gas under EIP-150, value transfer cost, cold account/storage access costs).
    - Ensure **JIT paths charge gas identically** to interpreted paths:
      - Either inject gas checks into JITed code, or structure execution so gas is decremented **before** executing a JITed basic block.
      - Confirm that parallel execution does not break global gas accounting and block gas limit.

---

### 3. Performance & Throughput Roadmap (Target: 200k TPS)

#### 3.1 Micro-level: Single-EVM execution speed
- **Eliminate unnecessary work in prologue/epilogue**
  - **Current state**: [compile_epilogue](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig#L208-L235) flushes **all virtual stack slots** to memory, even if many are dead at end.
  - **Pending optimizations**:
    - Track **liveness of virtual stack slots** and only flush those that are logically live at end-of-frame.
    - Consider a **"no flush" fast path** when the caller is only interested in top-of-stack or when the code is a terminal expression.

- **Better block formation and instruction scheduling**
  - Break bytecode into **basic blocks** and compile each block as a unit, enabling:
    - Common-subexpression elimination across instructions.
    - Load hoisting and store sinking around branches.
    - Better **register allocation across blocks** (rather than strictly stack-index based).

- **Constant folding and peephole optimizations**
  - Many benchmark programs are simple arithmetic/bitwise chains (see [benchmark_tps.zig](file:///Users/karan/zephyria/zig/src/vm/tests/benchmark_tps.zig)).
  - Add a **pre-pass** over bytecode to:
    - Fold `PUSH`+arith chains.
    - Eliminate dead `POP`/`SWAP`/`DUP` sequences.
    - Collapse simple control-flow patterns into straight-line code.

- **Native crypto acceleration**
  - Delegate heavy operations (e.g. Keccak/SHA3, ECDSA, BLS) to highly optimized libraries (`blst`, platform intrinsics), ideally compiled into **native stencils** or direct calls from JITed code.

#### 3.2 Macro-level: Parallelism & system architecture
- **Reuse warmed EVM instances per worker thread**
  - **Current state**: [executeOptimizedTransactionWork](file:///Users/karan/zephyria/zig/src/vm/parallel_optimized.zig#L573-L588) creates and destroys a new [EVM](file:///Users/karan/zephyria/zig/src/vm/main.zig) per transaction.
  - **Pending optimizations**:
    - Maintain a **pool of pre-initialized EVM instances** per worker, reusing:
      - Pre-allocated stacks and memory buffers.
      - JIT/compiler state where valid (code cache).
    - Avoid repetitive `EVM.init` and `loadOpcodes` in the hot path.

- **Transaction-level parallelization**
  - **Current state**: [OptimizedParallelScheduler](file:///Users/karan/zephyria/zig/src/vm/parallel_optimized.zig#L394-L565) builds an address-level dependency graph and runs waves of independent transactions.
  - **Pending work**:
    - Refine **dependency granularity**:
      - Move from **account-level conflicts** to **(account, storage-key)** level when access lists or static analysis are available.
      - Incorporate read/write sets from bytecode static analysis or execution traces.
    - Integrate **state snapshots & journaling** so each parallel worker can apply changes on a local view and merge deterministically.
    - Optimize wave scheduling to **keep all cores busy** even under skewed conflict patterns.

- **End-to-end pipeline for 200k TPS**
  - Model a realistic pipeline including:
    - Mempool ingestion and pre-sorting.
    - Dependency analysis and batching.
    - Parallel execution across N cores.
    - State commitment and trie updates (outside `src/vm`, but must be matched with VM throughput).
  - Use [benchmarkOptimizedExecution](file:///Users/karan/zephyria/zig/src/vm/parallel_optimized.zig#L613-L652) as the basis to **scale up to tens/hundreds of thousands of synthetic tx/s**, then gradually incorporate real contract mixes.

#### 3.3 Memory, allocation & cache behavior
- **Soft-MMU tuning**
  - Experiment with **larger page sizes** or huge pages if available to reduce TLB pressure.
  - Implement **lazy zeroing** and reuse of memory regions between transactions.

- **Allocator and memory pool usage**
  - Fully integrate [MemoryPool](file:///Users/karan/zephyria/zig/src/vm/parallel_optimized.zig#L284-L375) into EVM and storage paths where allocation hotspots exist.
  - Use `GeneralPurposeAllocator` or custom slab allocators tuned for small, frequent allocations (logs, temporary BigInts, call frames).

---

### 4. Security & Determinism Gaps

#### 4.1 JIT security (W^X, SFI, and sandboxing)
- **Executable memory safety**
  - **Current state**:
    - [NativeJitCompiler.init](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig#L51-L62) allocates RW JIT memory with `.JIT = true` and toggles protections via `pthread_jit_write_protect_np` and `mprotect`.
    - [finalize](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig#L84-L95) switches to RX and invalidates I-cache on Darwin.
  - **Pending work**:
    - Audit that **no writable-executable windows** are left open longer than necessary, especially on non-Darwin platforms (Linux/Windows JIT flags).
    - Consider **separate code regions per contract** vs shared buffers to avoid cross-contract code injection attacks.

- **Soft-MMU & SFI for VM memory**
  - **Current state**:
    - [Memory](file:///Users/karan/zephyria/zig/src/vm/memory.zig) reserves 4GB and uses `mprotect` for committed region.
    - Stencils in [stencils/memory.zig](file:///Users/karan/zephyria/zig/src/vm/stencils/memory.zig) use 32-bit truncated offsets to enforce 4GB addressing.
  - **Pending work**:
    - Prove that **untrusted bytecode cannot escape the reserved region**:
      - Validate all memory offsets and sizes before use.
      - Ensure no code path writes beyond `committed_len` without first committing pages.
    - Add **comprehensive tests and fuzzing** for out-of-bounds reads/writes and verify they are either zero/ignored or trapped, consistent with EVM semantics.

#### 4.2 Determinism across platforms and threads
- Ensure the following are **deterministic across nodes**:
  - JIT code generation is purely a function of bytecode and configuration; no dependence on wall-clock time, randomization, or non-deterministic CPU features.
  - Parallel scheduler’s wave-based execution yields **order-independent final state**:
    - Conflicts are fully captured by the dependency graph.
    - No race on shared state outside the designed merge points.
  - No reliance on **floating-point** or host-specific behavior for EVM semantics.

#### 4.3 DoS and resource exhaustion defenses
- Limit and enforce:
  - Maximum **JIT code size per contract** to prevent pathological bytecode from exploding code buffer usage.
  - Maximum **memory growth per execution** (even under high gas) to avoid multi-GB allocations.
  - Reasonable caps on **logs, return data, and calldata** lengths per transaction.

---

### 5. Testing, Verification & Tooling

#### 5.1 Spec and differential testing
- Integrate **Ethereum GeneralStateTests** and other official test suites via the FFI layer ([ffi.zig](file:///Users/karan/zephyria/zig/src/vm/ffi.zig)) or a thin harness.
- Run **differential tests** against one or more reference clients (geth, Besu, Nethermind):
  - Feed identical blocks/transactions and compare **state roots**, **logs**, **gas used**, and **return data**.
  - Ensure parity across all supported forks.

#### 5.2 Fuzzing & property-based testing
- Add fuzzing harnesses for:
  - Bytecode verifier ([verifier.zig](file:///Users/karan/zephyria/zig/src/vm/verifier.zig)).
  - Native JIT compiler ([native_compiler.zig](file:///Users/karan/zephyria/zig/src/vm/native_compiler.zig)) vs interpreter:
    - Generate random bytecode sequences within constraints, run both execution engines, and check equivalence.
  - Memory subsystem and SFI paths.

#### 5.3 Performance regression tests
- Extend [benchmark_tps.zig](file:///Users/karan/zephyria/zig/src/vm/tests/benchmark_tps.zig) and [benchmarkOptimizedExecution](file:///Users/karan/zephyria/zig/src/vm/parallel_optimized.zig#L613-L652):
  - Use **mixed workloads** (storage heavy, log heavy, call heavy) rather than only arithmetic.
  - Continuously track TPS across different hardware and configurations (core count, NUMA, etc.).

---

### 6. Concrete Checklist (High-Level)

- **Native JIT functional gaps**
  - [ ] Implement correct u256 DIV/REM/SDIV/SMOD in native JIT.
  - [ ] Implement register spilling and liveness-aware bank allocation.
  - [ ] Support arbitrary 256-bit constants in native codegen.
  - [ ] Fix JUMPI condition handling to account for full 256-bit stack value.
  - [ ] Align native MLOAD/MSTORE and stencils with proper memory expansion semantics and gas.

- **Opcode & gas completeness**
  - [ ] Implement JIT support for CALL, CALLCODE, DELEGATECALL, STATICCALL, CREATE, CREATE2.
  - [ ] Implement JIT support for LOG0–LOG4, EXTCODE* family, EXP, SHA3, BALANCE.
  - [ ] Make gas accounting fully Yellow-Paper & EIP-compliant (memory, SSTORE, CALL, refunds, warm/cold accesses).
  - [ ] Introduce fork configuration for gas and semantics.

- **Verifier & safety**
  - [ ] Wire real stack effects into `Verifier.buildCFG` and complete `getStackEffect` coverage.
  - [ ] Enforce valid JUMPDEST targets and strengthen unreachable/infinite-loop detection.
  - [ ] Integrate verifier into JIT path to reject invalid bytecode before codegen.

- **Performance & parallelism**
  - [ ] Optimize prologue/epilogue to avoid unnecessary stack flushes.
  - [ ] Add basic block-level optimizations (constant folding, peephole passes).
  - [ ] Reuse warmed EVM instances and code caches in worker threads.
  - [ ] Refine dependency analysis to storage-key granularity and improve wave scheduling.
  - [ ] Tune Soft-MMU, memory pools, and allocator settings for high TPS workloads.

- **Security, determinism & testing**
  - [ ] Audit JIT W^X behavior and platform-specific JIT flags.
  - [ ] Prove SFI guarantees and add OOB memory fuzz tests.
  - [ ] Ensure determinism across OS/CPU variants and multi-threaded execution.
  - [ ] Integrate Ethereum official tests and differential testing vs reference clients.
  - [ ] Extend fuzzing, property tests, and performance regression benchmarks.

This checklist, once completed, should bring the Zig native VM much closer to a **production-ready, high-throughput, register-based EVM** capable of approaching or exceeding the **200k TPS** target under favorable workloads and hardware.
