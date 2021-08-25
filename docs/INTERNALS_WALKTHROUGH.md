# Anvil Internals Walkthrough: The Lifecycle of a Revision

This document provides a low-level, step-by-step trace through memory, disk I/O, and data structures during three fundamental version control operations in Anvil:
1. `anvil commit` (Snapshot creation)
2. `anvil merge` (Three-way reconciliation)
3. `anvil push` (Network packfile streaming)

---

## 1. Anatomy of `anvil commit`

When the user runs `anvil commit -m "feat: parse tokens"`, the following sequence of operations occurs:

```
[ Working Copy ] ---- modified files ----> [ Staging Index (DIRC) ]
                                                    |
                                            write-tree traversal
                                                    v
[ Object Database ] <--- write blobs & trees --- [ In-Memory Tree Hierarchy ]
        |
        +-- create commit object (pointing to root tree + parent commits)
        |
        +-- atomic write loose commit (.anvil/objects/xx/yyyy...)
        |
[ Reference Manager ] <--- update symref/ref (refs/heads/main)
        |
[ Reference Log ] <--- append history entry (.anvil/logs/refs/heads/main)
```

### Step 1: Synthesizing the Tree Hierarchy (`write-tree`)
1. The engine locks `.anvil/index` and loads all sorted `TIndexEntry` records into memory.
2. Anvil scans file paths hierarchically. For entries sharing directory prefixes (e.g. `src/crypto/anvil_sha1.pas`), it groups entries and recursively instantiates `TTreeObject` instances.
3. For each subdirectory:
   - Serializes entries into the canonical binary tree format: `[octal_mode] [space] [filename] [\0] [binary_hash]`.
   - Computes the SHA-1 or SHA-256 digest of `tree <size>\0<payload>`.
   - Writes loose object to disk if not already present in the ODB.
   - Embeds the subtree's hash and mode (`040000`) into the parent tree.
4. Emits the single 40-character hexadecimal root tree hash.

### Step 2: Assembling the Commit Object
1. Allocates `TCommitObject`.
2. Sets `TreeId` to the newly minted root tree hash.
3. Resolves the current `HEAD` reference (e.g. `refs/heads/main`). If `HEAD` points to an existing commit, adds that hash to `ParentIds`.
4. Populates author and committer identities with current UNIX epoch seconds and local timezone offset.
5. Appends commit message text.
6. Serializes into commit format:
   ```
   commit <size>\0
   tree <root_tree_id>
   parent <parent_id>
   author Aneesh Krishna <aneesh@example.com> 1700000000 -0500
   committer Aneesh Krishna <aneesh@example.com> 1700000000 -0500

   feat: parse tokens
   ```
7. Compresses via DEFLATE and writes to `.anvil/objects/xx/yyyy...` using atomic file renaming.

### Step 3: Reference and Reflog Update
1. Atomically updates `.anvil/refs/heads/main` to contain the new commit hash followed by a newline.
2. Opens `.anvil/logs/refs/heads/main` and appends a single reflog entry:
   `[old_hash] [new_hash] Aneesh Krishna <aneesh@example.com> 1700000000 -0500\tcommit: feat: parse tokens\n`.

---

## 2. Anatomy of `anvil merge`

When the user runs `anvil merge feature-branch` from `main`:

```
           (O) Merge Base (LCA)
          /   \
         /     \
  (A) HEAD      (B) Feature Branch
         \     /
          \   /
           (M) Merge Commit
```

### Step 1: Discovering the Merge Base
1. Loads target commit $A$ (`HEAD`) and incoming commit $B$ (`refs/heads/feature-branch`).
2. Instantiates `TLcaFinder`.
3. Traverses the commit DAG backward using generation numbers and priority queues.
4. Identifies ancestor commit $O$ where histories diverged.
5. If $O = B$, the current branch is already up to date (no-op).
6. If $O = A$, Anvil performs a **fast-forward**: updates `refs/heads/main` directly to $B$ and checks out $B$'s tree.

### Step 2: Three-Way Tree Traversal
If histories have genuinely diverged:
1. `TTreeMerger` loads root trees for $O$, $A$, and $B$.
2. Recursively walks directory entries in lockstep:
   - File exists in $A$ and $B$ with different hashes: triggers three-way file merge.
   - File added only in $B$: accepted into working tree and index.
   - File deleted only in $B$: deleted from working tree and index.

### Step 3: File Reconciliation and Conflict Handling
For modified files:
1. Reads raw blob payloads for ancestor, ours, and theirs.
2. Invokes `ThreeWayMergeStrings(AncestorText, OurText, TheirText)`.
3. If changes affect distinct line ranges, clean merged text is written to disk and staged at Stage 0.
4. If overlapping edits conflict:
   - Emits diff3 markers into the working tree file.
   - Writes ancestor blob to Stage 1, our blob to Stage 2, and their blob to Stage 3 in `.anvil/index`.
   - Signals conflict state to user and halts commit progression until resolved.

---

## 3. Anatomy of `anvil push`

When pushing to a remote Git server:

```
[ Client ]                                                   [ Remote Server ]
    |                                                                |
    | --- pkt-line: git-receive-pack /repo.git --------------------> |
    | <--- pkt-line: ref advertisement & capabilities -------------- |
    |                                                                |
    | --- pkt-line: old_hash new_hash refs/heads/main -------------> |
    | --- pkt-line: flush-pkt (0000) ------------------------------> |
    |                                                                |
    | [ Delta Compactor: Pack required commits, trees, blobs ]       |
    |                                                                |
    | === Sideband channel 1: Contiguous .pack byte stream ========> |
    | <=== Sideband channel 2: Human progress updates ============== |
    |                                                                |
    | <--- pkt-line: unpack ok / ok refs/heads/main ---------------- |
```

1. **Handshake**: Client initiates connection and negotiates protocol capabilities (`report-status`, `sideband-64k`, `ofs-delta`).
2. **Ref Negotiation**: Server advertises current remote heads. Client calculates missing object set using DAG reachability traversal ($Target \setminus Remote$).
3. **Pack Generation**: Client packs all missing commits, trees, and blobs into a temporary in-memory packfile, applying byte-level delta compression to shared bases.
4. **Multiplexed Transfer**: The pack stream is framed inside sideband packets (`[4-hex-len][0x01][pack_chunk]`) and piped to the remote server.
5. **Atomic Ref Update**: Remote server unpacks the stream, verifies SHA-1 checksums, and updates branch pointers.
