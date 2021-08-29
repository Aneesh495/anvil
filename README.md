# Anvil

**A High-Performance, Git-Compatible Distributed Version Control and Content-Addressable Storage Engine in Modern Object Pascal.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Compiler: Free Pascal](https://img.shields.io/badge/FPC-3.2.2%2B-orange.svg)](https://www.freepascal.org/)
[![Tests: 286 Passing](https://img.shields.io/badge/Tests-286%20Passed%20(100%25)-brightgreen.svg)]()
[![Platform: macOS | Linux](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-lightgrey.svg)]()

Anvil is a complete, standalone distributed version control system and content-addressable object store engineered from first principles in Free Pascal (`objfpc` dialect). It features native binary and protocol compatibility with canonical Git repositories while delivering deterministic execution, zero runtime garbage collection pauses, and low memory overhead.

In addition to its native CLI binary, Anvil exports a clean C ABI dynamic library (`libanvil`) and type-safe Python bindings (`pyanvil`), enabling seamless embedding into external runtimes and automation pipelines.

---

## Architecture Overview

```
+-----------------------------------------------------------------------------+
|                                Anvil Porcelain                              |
|   init | status | add | rm | commit | branch | checkout | merge | rebase    |
|   cherry-pick | reset | log | diff | blame | tag | gc | fsck                |
+-----------------------------------------------------------------------------+
                                       |
+-----------------------------------------------------------------------------+
|                             High-Level Subsystems                           |
|   Worktree Engine   |   DAG Walker & Blame   |   3-Way Tree Merge & Rebase  |
|   (Ignore, Status)  |   (Topo / Chro / LCA)  |   (Myers SES & Patience)     |
+-----------------------------------------------------------------------------+
                                       |
+-----------------------------------------------------------------------------+
|                             Core Storage & Wire                             |
|   Staging Cache (dircache) | Reference Manager | Git Smart Wire Protocol    |
|   (Binary Index Format v2) | (Packed-Refs & Log)| (Pkt-Line & Sideband-64k)  |
+-----------------------------------------------------------------------------+
                                       |
+-----------------------------------------------------------------------------+
|                         Object Database Layer (ODB)                         |
|   Loose Objects (zlib deflated) | Packfile Engine v2 (OFS/REF Delta + Idx2)  |
+-----------------------------------------------------------------------------+
                                       |
+-----------------------------------------------------------------------------+
|                        Cryptographic & Common Primitives                    |
|   SHA-1 | SHA-256 | CRC-32 | CRC-32C | Zero-Copy Byte Spans | Ring Buffers  |
+-----------------------------------------------------------------------------+
```

---

## Subsystem Capabilities

### 1. Cryptographic Primitives & Storage
- **Dual Hash Agility**: Full support for both 160-bit SHA-1 (Git legacy) and 256-bit SHA-256 (modern collision-resistant repositories), conforming to NIST FIPS 180-1 and FIPS 180-4.
- **High-Throughput Checksums**: Optimized slice-by-8 and 256-entry lookup tables for IEEE 802.3 CRC-32 and Castagnoli CRC-32C (>400 MB/s).
- **Loose Storage**: Atomic zlib-compressed object storage under `.anvil/objects/xx/yyyy...` using copy-on-write tempfile renames.
- **Packfile v2 Engine**: Contiguous binary container storage supporting variable-length integer encoding, `OBJ_OFS_DELTA` relative negative byte offset bases, and 256-way fanout index tables (`.idx` v2) for $O(\log_2(N/256))$ object resolution.

### 2. Directory Cache & Worktree Tracking
- **Binary Index Format v2 (`DIRC`)**: Memory-mapped binary staging area storing cached filesystem stat metadata (dev, ino, mode, uid, gid, size, mtime, ctime) to detect modifications without hashing unmodified content.
- **Conflict Stages**: Native tracking of conflicting paths across Stage 1 (ancestor base), Stage 2 (ours / HEAD), and Stage 3 (theirs / incoming).
- **Gitignore Engine**: Full recursive globstar (`**`), character classes, directory anchors, and negative rule (`!`) support.
- **Dirty Tree Protection**: Refuses destructive checkouts or resets when uncommitted local changes would be overwritten.

### 3. Difference and Merge Algorithms
- **Myers O(ND) Shortest Edit Script (SES)**: Optimal edit graph traversal algorithm computing minimal insertions and deletions with $O(ND)$ time complexity.
- **Patience Diff**: Unique-line anchoring and Longest Common Increasing Subsequence (LCIS) resolution designed to produce clean diffs across structured code blocks.
- **Rename & Copy Detection**: Computes Dice/Jaccard line-level similarity coefficients to pair deleted and created files as renames.
- **Lowest Common Ancestor (LCA)**: Topological DAG analysis with generation numbering to determine optimal merge bases.
- **Three-Way Reconciliation**: Line-level merge3 with conflict marker emission and recursive hierarchical tree-to-tree merge.

### 4. Revision DAG & Provenance
- **Revision Syntax Parser**: Resolves branch heads, tags, caret syntax (`HEAD^`, `HEAD^2`), tilde syntax (`HEAD~4`), reflog queries (`HEAD@{2}`), and range notation (`A..B`, `A...B`).
- **DAG Walkers**: Topological sorting (Kahn's algorithm) and chronological timestamp priority queues with path-limited filtering.
- **Line Blame**: Line-by-line origin attribution tracing backwards across commit history.
- **ASCII Terminal Graph**: Multi-column graphical commit log renderer showing merge joins, forks, and branch labels.

### 5. Git Smart Wire Protocol
- **Pkt-Line Framing**: Standard 4-hex prefixed lines, flush (`0000`), delimiter (`0001`), and response end (`0002`) frames.
- **Sideband-64k Multiplexer**: Demultiplexes pack payload (channel 1), human progress messages (channel 2), and errors (channel 3).
- **Smart Wire Client & Server**: Native reference discovery, want/have negotiation, and delta packfile transfer.

---

## Micro-Benchmark Performance

Micro-benchmarks executed on Apple Silicon (Free Pascal Compiler 3.2.2, `-O3` optimization):

| Subsystem | Metric | Throughput / Latency |
| :--- | :--- | :--- |
| **SHA-1 Digest** | 32 MB continuous byte stream | **248.06 MB/s** |
| **SHA-256 Digest** | 32 MB continuous byte stream | **196.32 MB/s** |
| **CRC-32 (IEEE 802.3)** | 32 MB continuous byte stream | **376.47 MB/s** |
| **CRC-32C (Castagnoli)**| 32 MB continuous byte stream | **410.26 MB/s** |
| **Myers O(ND) Diff** | 3,000 lines synthetic source | **375,000 lines/s** |
| **Patience Diff** | 3,000 lines synthetic source | **100,000 lines/s** |
| **Loose Object Write** | Ingesting and compressing blobs | **4,761 objects/s** |
| **Loose Object Read** | Hydrating and decompressing | **1,500,000 objects/s** |
| **DAG History Walk** | Topological commit ordering | **400,000 commits/s** |

Run benchmarks locally:
```bash
make bench
```

---

## Quickstart

### 1. Build from Source
Prerequisites: Free Pascal Compiler (`fpc` 3.2.0 or newer) and standard POSIX make.

```bash
git clone https://github.com/Aneesh495/anvil.git
cd anvil
make all
```

Build targets:
- `bin/anvil`: Standalone CLI binary.
- `lib/libanvil.dylib` (or `.so`): C foreign function interface dynamic library.
- `bin/anvil_test`: Complete verification suite.
- `bin/anvil_bench`: Micro-benchmark runner.

### 2. Basic CLI Workflow
```bash
# Initialize a new repository
anvil init my_project
cd my_project

# Create a source file
echo "program Main; begin Writeln('Hello Anvil'); end." > main.pas

# Stage and commit
anvil add main.pas
anvil commit -m "feat: initial program setup"

# Create and switch to a feature branch
anvil branch feature/optimizer
anvil checkout feature/optimizer

# Modify file and commit
echo "procedure Optimize; begin end;" >> main.pas
anvil add main.pas
anvil commit -m "feat: add optimizer stub"

# Switch back and merge cleanly
anvil checkout main
anvil merge feature/optimizer

# View formatted DAG history
anvil log --graph --oneline
```

### 3. Programmatic Usage in Python (`pyanvil`)
```python
from pyanvil import Repository, hash_bytes

# Fast cryptographic hashing
blob_id = hash_bytes(b"fn calculate() -> i32 { 42 }\n")
print(f"Content ID: {blob_id}")

# Repository automation
repo = Repository.init("/tmp/project")
with open("/tmp/project/lib.py", "w") as f:
    f.write("def add(a, b): return a + b\n")

repo.add(["lib.py"])
cid = repo.commit(
    message="feat: add math library",
    author_name="Aneesh Krishna",
    author_email="aneesh@example.com"
)
print(f"Committed: {cid}")

status = repo.status()
print(f"Active Branch: {status.branch}, Clean: {status.is_clean}")
```

---

## Repository Structure

```
anvil/
├── src/
│   ├── common/          # Core types, errors, zero-copy buffers, string utilities
│   ├── crypto/          # SHA-1, SHA-256, CRC-32, CRC-32C, ObjectId hash maps
│   ├── odb/             # Loose object storage, packfile v2, index v2, delta compression
│   ├── index/           # DIRC v2 binary directory cache, stage conflicts, write-tree
│   ├── diff/            # Myers O(ND) SES, Patience diff, tree walker, rename detector
│   ├── merge/           # LCA calculation, merge3 line reconciliation, tree merge, rebase
│   ├── ref/             # Symbolic reference manager, packed-refs, reflog, commit-graph
│   ├── worktree/        # Gitignore globstar matcher, status scanner, safe checkout
│   ├── dag/             # Revision parser, topological/chronological walker, blame, graph
│   ├── protocol/        # Git smart wire framing (pkt-line, sideband-64k, upload/receive pack)
│   ├── cli/             # 25+ porcelain and plumbing CLI commands and entrypoint router
│   └── lib/             # C ABI dynamic shared library (libanvil)
├── include/             # C99 header prototypes (anvil.h)
├── bindings/
│   └── python/          # pyanvil ctypes wrapper package and unit tests
├── tests/
│   ├── unit/            # Unit verification suites across all subsystems
│   ├── integration/     # End-to-end repository lifecycle workflows
│   └── test_runner.pas  # Verification runner (286 test assertions)
├── benchmarks/          # Performance and throughput micro-benchmarking harness
├── docs/                # In-depth architectural and algorithmic specifications
├── Makefile             # Multi-target build configuration
└── LICENSE              # MIT License
```

---

## Technical Documentation

- [Architecture Specification](docs/ARCHITECTURE.md): Comprehensive review of subsystems, data flows, and memory layouts.
- [Packfile and Index v2 Binary Specification](docs/PACK_FORMAT.md): Bit-level encoding of packfiles, OFS_DELTA, and 256-way fanout tables.
- [Merge and Difference Algorithms](docs/MERGE_ALGORITHMS.md): Mathematical walkthrough of Myers SES, Patience LCIS, and 3-way reconciliation.
- [Command-Line Reference](docs/CLI_REFERENCE.md): Detailed parameter guide for all porcelain and plumbing commands.
- [Python Bindings (`pyanvil`)](docs/PYTHON_BINDINGS.md): Programmatic C ABI wrapper reference.
- [Internals Walkthrough](docs/INTERNALS_WALKTHROUGH.md): Step-by-step trace through memory and disk during commit, merge, and push.

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
