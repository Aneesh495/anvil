# Anvil Architecture Specification

Anvil is a Git-compatible distributed version control engine and content-addressable storage system written in modern Object Pascal (Free Pascal). It provides both low-level repository plumbing and high-level porcelain tooling, maintaining strict binary and protocol compatibility with standard Git repositories while executing with zero managed runtime overhead.

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

## 1. Core Architectural Tenets

1. **Deterministic Content-Addressability**: All stored filesystem artifacts (blobs, trees, commits, tags) are keyed by their cryptographic digest. Changing a single byte in any file produces a completely distinct identifier and cascades up the root tree.
2. **Explicit Memory Control**: Built with Free Pascal's `objfpc` dialect with long strings enabled, all buffers, stream pipelines, and tree node structures are allocated deterministically without garbage collection pauses or background thread interruptions.
3. **Dual Hash Agility**: Full support for both 160-bit SHA-1 (standard Git legacy compatibility) and 256-bit SHA-256 (modern collision-resistant repositories), abstracted behind the uniform `TObjectId` record.
4. **Git Binary Wire Compatibility**: Native support for pkt-line framing, sideband-64k multiplexed progress and error streams, and smart HTTP / SSH capability negotiation.

---

## 2. Cryptographic and Hashing Subsystem

The cryptographic layer (`src/crypto`) implements hand-optimized digest algorithms conforming strictly to NIST and RFC specifications:

- **SHA-1** (`anvil_sha1.pas`): 512-bit block processor implementing the four non-linear transformation rounds with big-endian message scheduling. Validated against NIST FIPS 180-1 vectors.
- **SHA-256** (`anvil_sha256.pas`): 256-bit hash engine implementing the eight working variables (a through h), fractional cube-root round constants $K_t$, and Sigma/Sigma-prime permutations. Conforms to NIST FIPS 180-4.
- **CRC-32 & CRC-32C** (`anvil_crc32.pas`): 8-bit slice-by-8 and precomputed 256-entry lookup tables for IEEE 802.3 ethernet polynomial (`0xEDB88320`) and Castagnoli SSE4.2 polynomial (`0x82F63B78`), achieving verification throughput exceeding 400 MB/s.
- **Object Identification** (`anvil_hash.pas`): The canonical `TObjectId` record stores raw 20-byte or 32-byte digest buffers alongside hexadecimal conversion routines and hash tables (`TObjectIdSet`, `TObjectIdMap`) backed by Murmur3 bit-mixers.

---

## 3. Content-Addressable Storage (ODB)

The Object Database (`src/odb`) manages both loose uncompressed/compressed files and high-density delta-compressed packfiles:

```
.anvil/objects/
├── 4b/
│   └── 825dc642cb6eb9a060e54bf8d69288fbee4904   <-- Loose empty tree
├── 8a/
│   └── e9d6e848b1d9230531c3600c28254ff0c31278   <-- Loose blob
├── info/
│   └── commit-graph                              <-- Linearized DAG cache
└── pack/
    ├── pack-1a2b3c4d5e6f.pack                    <-- Compressed binary pack
    └── pack-1a2b3c4d5e6f.idx                     <-- 256-way fanout index
```

### Loose Object Storage
Loose objects reside at `.anvil/objects/xx/yyyy...` where `xx` is the first two hexadecimal characters of the digest and `yyyy...` is the remaining suffix. The payload format is:

```
[type_string] [space] [size_in_ascii_bytes] [\0] [binary_payload]
```

The entire header and payload are compressed with standard DEFLATE (zlib RFC 1950) before committing to disk via an atomic temporary file rename (`TAtomicFileWriter`).

### Packfile Engine v2
Packfiles store multiple objects sequentially inside a single contiguous binary container. Heavy duplication across revisions is compressed using byte-level copy-insert deltas (`anvil_delta.pas`):
- Variable-length integer headers indicate object type (`OBJ_COMMIT`, `OBJ_TREE`, `OBJ_BLOB`, `OBJ_TAG`, `OBJ_OFS_DELTA`, `OBJ_REF_DELTA`).
- Negative relative byte offsets (`OBJ_OFS_DELTA`) reference base objects earlier in the same packfile.
- 256-way fanout index tables (`.idx` v2) accelerate binary lookups from $O(N)$ to $O(\log_2(N/256))$, guarded by table CRC-32 values and packfile trailer checksums.

---

## 4. Staging Area (Directory Cache Index)

The staging index (`src/index/anvil_index.pas`) coordinates changes between the working directory tree and the committed object database. Binary format v2 layout:

```
+-------------------------------------------------------------------+
| 4-byte Magic: 'DIRC' (0x44495243)                                 |
+-------------------------------------------------------------------+
| 4-byte Version: 2                                                 |
+-------------------------------------------------------------------+
| 4-byte Entry Count: N                                             |
+-------------------------------------------------------------------+
| Entry 1: ctime, mtime, dev, ino, mode, uid, gid, size, id, flags  |
|          path string (null-terminated), 1-8 null padding bytes    |
+-------------------------------------------------------------------+
| ...                                                               |
+-------------------------------------------------------------------+
| Entry N: ...                                                      |
+-------------------------------------------------------------------+
| Optional Extensions: 'TREE' (Cached Trees), 'REUC' (Resolve Undo) |
+-------------------------------------------------------------------+
| 20-byte SHA-1 Trailer Checksum across all preceding bytes         |
+-------------------------------------------------------------------+
```

During three-way merges with unresolved conflicts, multiple stages coexist in the index:
- **Stage 0**: Normal staged file (clean).
- **Stage 1**: Ancestor revision (merge base).
- **Stage 2**: Target branch revision (ours / HEAD).
- **Stage 3**: Incoming branch revision (theirs / remote).

---

## 5. Differential Comparison and Merge Engine

### Myers O(ND) Shortest Edit Script (SES)
The default difference algorithm (`src/diff/anvil_myers.pas`) explores the edit graph from $(0, 0)$ to $(N, M)$ diagonally. It calculates the furthest-reaching paths for edit distance $D \in [0, N+M]$, generating minimal unified diff hunks with $O(ND)$ time complexity and $O(D^2)$ space complexity.

### Patience Diff Algorithm
For source code containing repetitive syntax (brackets, end statements, boilerplate), the patience diff algorithm (`src/diff/anvil_patience.pas`) isolates uniquely occurring lines in both buffers, constructs the Longest Common Increasing Subsequence (LCIS) via patience sorting, and recursively solves sub-regions.

### 3-Way Reconciliation and LCA
When merging branches (`src/merge`):
1. **Lowest Common Ancestor (LCA)** (`anvil_lca.pas`): Computes merge bases by traversing the commit graph backwards using generation numbers and priority queues.
2. **Three-Way Line Reconciler** (`anvil_merge3.pas`): Compares ancestor, ours, and theirs. Non-conflicting edits are merged cleanly; conflicting overlapping line spans emit Git standard conflict markers:
   ```
   <<<<<<< HEAD
   local implementation
   =======
   incoming remote implementation
   >>>>>>> feature-branch
   ```
3. **Recursive Tree Merger** (`anvil_merge_tree.pas`): Traverses directory trees hierarchically, staging clean modifications in Stage 0 and conflicting paths in Stages 1, 2, and 3.

---

## 6. Revision DAG Traversal & Provenance

The DAG subsystem (`src/dag`) manages commit graph histories:
- **Revision Range Parser** (`anvil_revision.pas`): Evaluates branch names, short/long object IDs, caret syntax (`HEAD^`, `HEAD^2`), tilde syntax (`HEAD~4`), reflog syntax (`HEAD@{2}`), and range notation (`main..feature`, `A...B`).
- **Topological and Chronological Walker** (`anvil_dag.pas`): Implements in-degree tracking and Kahn's algorithm for topological sorting, and priority queues for timestamp ordering.
- **Line Blame Engine** (`anvil_blame.pas`): Annotates every line in a source file with its origin commit, author, and timestamp by walking history backwards and computing line-level diffs until all lines are blamed.
- **ASCII Graph Visualizer** (`anvil_graph_view.pas`): Synthesizes multi-column terminal branch graphs showing branching, merging, commit nodes (`*`), and ref tags (`(HEAD -> main, tag: v1.0.0)`).

---

## 7. Git Smart Wire Protocol

The networking protocol layer (`src/protocol`) implements the native Git Smart Protocol:
- **Pkt-Line Framing** (`anvil_pktline.pas`): 4-character hex length-prefixed chunks (`000ahello\n`), flush packets (`0000`), delimiter packets (`0001`), and response end packets (`0002`).
- **Sideband-64k Multiplexing** (`anvil_sideband.pas`): Channels binary packfile data (channel 1), human progress updates (channel 2), and severe diagnostic errors (channel 3) over a single duplex byte stream.
- **Smart Wire Client & Server** (`anvil_wire_client.pas`, `anvil_wire_server.pas`): Full handshake lifecycle supporting reference advertisement, `want`/`have` object set negotiation, common ancestor discovery, and delta packfile streaming.
