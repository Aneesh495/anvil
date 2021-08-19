# Anvil Command-Line Interface (CLI) Reference

The `anvil` command line utility provides both high-level porcelain commands for daily source control workflows and low-level plumbing commands for automation, scripting, and inspection.

---

## Exit Codes

All Anvil commands exit with standard status codes:
- `0`: Success. Operation completed cleanly.
- `1`: Non-fatal failure (e.g. merge conflicts detected, diff found changes with `--exit-code`).
- `2`: Command-line usage error or invalid argument syntax.
- `128`: Repository corruption, missing objects, or fatal I/O error.

---

## 1. Porcelain Commands

### `anvil init [path] [--bare]`
Initializes a new Anvil repository:
- `path`: Target directory (defaults to current directory).
- `--bare`: Create an unmanaged bare repository without a working directory tree.

### `anvil status`
Displays working tree status, staged changes, unstaged modifications, untracked files, and unresolved conflict stages.

### `anvil add <path>...`
Stages file modifications into the directory cache (`.anvil/index`):
- `.` or `path`: Adds specified file or recursively adds matching directory contents.
- Automatically resolves merge conflict stages into Stage 0 if resolved.

### `anvil rm <path>... [--cached]`
Removes files from the working tree and staging index:
- `--cached`: Only removes entries from the staging index, preserving the working tree copy.

### `anvil commit -m <message> [--author <identity>]`
Records staged changes into a new commit object:
- `-m, --message <text>`: Commit message.
- `--author "Name <email>"`: Override author identity.
- Advances current branch reference and creates a new reflog record.

### `anvil branch [name] [-d <name>] [-a]`
Inspects and manages branches:
- No arguments: Lists local branch heads with active branch highlighted.
- `name`: Creates a new branch head pointing to current `HEAD`.
- `-d, --delete <name>`: Deletes the specified branch head.
- `-a, --all`: Lists local and remote-tracking branch references.

### `anvil checkout <branch-or-commit> [-b <new-branch>]`
Switches branches or restores working tree files:
- `<target>`: Branch name or commit object ID.
- `-b <new>`: Atomically creates and checks out the new branch.
- Protects uncommitted dirty changes from accidental loss.

### `anvil diff [revision] [--cached] [--patience]`
Compares changes between trees, the index, and working copy:
- No arguments: Diffs working tree against index.
- `--cached, --staged`: Diffs index against `HEAD` commit tree.
- `<rev1> <rev2>`: Diffs arbitrary commits or tree objects.
- `--patience`: Activates patience diff algorithm.

### `anvil merge <branch>`
Reconciles divergent branches:
- Automatically performs fast-forward merge if target is an ancestor.
- Executes 3-way tree merge via Lowest Common Ancestor.
- If conflicts arise, conflict markers are written to disk and stages 1/2/3 are retained in the index.

### `anvil rebase <upstream>`
Linearly replays commits from the current branch on top of `<upstream>`:
- Isolates unique commits, finds merge base, resets `HEAD` to upstream, and cherry-picks each commit in sequence.

### `anvil cherry-pick <commit>`
Applies the differential patch of `<commit>` onto the current working tree and creates a new commit.

### `anvil reset [--soft | --mixed | --hard] <commit>`
Resets current `HEAD` to specified state:
- `--soft`: Moves `HEAD` ref only; index and working tree remain untouched.
- `--mixed` (default): Moves `HEAD` and resets index to match target commit.
- `--hard`: Moves `HEAD`, resets index, and overwrites working tree to match target commit.

### `anvil log [--oneline] [--graph] [-n <count>]`
Displays commit history:
- `--oneline`: Compact output formatting with 7-character hexadecimal prefix.
- `--graph`: Renders terminal ASCII multi-column DAG branch graph.
- `-n, --max-count <N>`: Limits display to $N$ most recent commits.

### `anvil blame <file>`
Displays line-by-line attribution for a source file, showing commit hash, author name, timestamp, and line number.

### `anvil tag [name] [-d <name>]`
Manages repository tags:
- No arguments: Lists existing tags.
- `name`: Creates a lightweight tag at current `HEAD`.
- `-d, --delete <name>`: Removes the specified tag.

### `anvil gc`
Housekeeping command that packs loose objects into packed containers (`.pack` and `.idx`) with delta compression and removes redundant loose files.

### `anvil fsck`
Integrity verification engine:
- Traverses all reachable objects from all refs and reflogs.
- Verifies SHA-1 / SHA-256 digests against payload contents.
- Validates packfile trailers and 256-way fanout index tables.

---

## 2. Plumbing Commands

### `anvil cat-file (-t | -s | -p) <object-id>`
Inspects raw object database entries:
- `-t`: Emits object type (`blob`, `tree`, `commit`, `tag`).
- `-s`: Emits uncompressed payload byte size.
- `-p`: Pretty-prints formatted object content.

### `anvil hash-object [-w] [-t <type>] <file>`
Calculates the content-addressable hash of a file:
- `-w`: Writes object into `.anvil/objects`.
- `-t <type>`: Specifies object type (default: `blob`).

### `anvil ls-tree [-r] <tree-ish>`
Lists directory tree object contents:
- `-r`: Recurses hierarchically into subtrees.

### `anvil write-tree`
Synthesizes a persistent tree object in the ODB from the staging index and emits the resulting root tree ID.

### `anvil read-tree <tree-ish>`
Populates the staging index with the contents of the given tree object.

### `anvil commit-tree <tree-id> -m <msg> [-p <parent-id>...]`
Creates a raw commit object pointing directly to `<tree-id>` without modifying `HEAD` or the index.

### `anvil rev-parse <revision>`
Resolves revision syntax (`HEAD`, `main~2`, `v1.0.0^{commit}`) into a raw 40-character hexadecimal object ID.

### `anvil rev-list [--topo-order] [--max-count=N] <commit>...`
Lists commit IDs in specified traversal order.
