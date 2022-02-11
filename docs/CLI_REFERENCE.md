# Anvil Command-Line Interface (CLI) Reference

The `anvil` command line utility provides both high-level porcelain commands for daily source control workflows and low-level plumbing commands for automation, scripting, and inspection.

---

## Exit Codes

The CLI currently uses these status codes:
- `0`: Success. Operation completed cleanly.
- `1`: A command-reported failure, including invalid arguments, an unknown command, a missing repository, or merge conflicts.
- `128`: An exception escaped the command and was reported by the top-level fatal-error handler, for example a filesystem write failure.

There is no separate usage-error status `2`. `diff` does not currently implement `--exit-code`; a successful comparison returns `0` even when it prints changes.

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
- Naming a tracked file that has been removed from disk stages its deletion.
- Naming a directory also stages deletions of tracked files within that directory.
- Automatically resolves merge conflict stages into Stage 0 if resolved.

### `anvil rm [-f] [--cached] <path>...`
Removes files from the working tree and staging index:
- Use `--cached` to remove an index entry while keeping the working file. The index entry must match either `HEAD` or the working file unless you also pass `-f`.
- Regular removal refuses paths with staged or unstaged content changes. Use `-f` or `--force` to override that check.

### `anvil commit -m <message> [--author <identity>]`
Records staged changes into a new commit object:
- `-m, --message <text>`: Commit message.
- `--author "Name <email>"`: Override author identity.
- Advances current branch reference and creates a new reflog record.

### `anvil branch [name] [-d <name> | -D <name>] [-a]`
Inspects and manages branches:
- No arguments: Lists local branch heads with active branch highlighted.
- `name`: Creates a new branch head pointing to current `HEAD`.
- Use `-d` or `--delete` to delete a branch whose tip is reachable from `HEAD`.
- Use `-D` to delete a branch without the merge check. The checked-out branch remains protected.
- `-a, --all`: Lists local and remote-tracking branch references.

### `anvil checkout <branch-or-commit> [-b <new-branch>]`
Switches branches or restores working tree files:
- `<target>`: Branch name or commit object ID.
- `-b <new>`: Atomically creates and checks out the new branch.
- Protects uncommitted dirty changes from accidental loss.

### `anvil diff [revision] [--cached]`
Compares changes between trees, the index, and working copy:
- No arguments: Diffs working tree against index.
- `--cached, --staged`: Diffs index against `HEAD` commit tree.
- `<rev1> <rev2>`: Diffs arbitrary commits or tree objects.

The CLI currently generates patches with Myers diff. The engine's patience implementation is not exposed by a `--patience` CLI option.

### `anvil merge <branch>`
Reconciles divergent branches:
- Automatically performs a fast-forward merge when the current HEAD is an ancestor of the target.
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
- Enumerates stored objects and reports objects the database cannot read.
- Checks that tree entries, commit trees, and commit parents refer to existing objects.
- Checks resolved references for missing target objects.

This command does not currently walk reflogs or independently recompute every object's digest, pack trailer, and index fanout table. A successful result covers the checks above rather than a complete Git-compatible `fsck` audit.

---

## 2. Plumbing Commands

### `anvil cat-file [-t | -s | -p | -e] <object-id>`
Inspects raw object database entries:
- `-t`: Emits object type (`blob`, `tree`, `commit`, `tag`).
- `-s`: Emits uncompressed payload byte size.
- `-p`: Pretty-prints formatted object content.
- Use `-e` to check that an object is readable. The command reports success or absence through its exit status.

### `anvil hash-object [-w] [-t blob] [--] <file>`
Calculates the content-addressable hash of a file:
- `-w`: Writes object into `.anvil/objects`.
- `-t blob`: Selects the supported object type, which is also the default.
- Use `--` before a filename that starts with a dash.

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
Resolves references, object IDs, ancestor expressions such as `main~2` and `HEAD^`, and reflog expressions such as `main@{0}` into a raw hexadecimal object ID. Git's typed peeling syntax, such as `v1.0.0^{commit}`, is not currently supported by the revision parser.

### `anvil rev-list [--topo-order] [--max-count=N] [<revision>...]`
Lists commit IDs in topological order from the supplied revisions or ranges. When no revision is supplied, the walk starts at `HEAD`. An unresolved revision or range exits with an error.

Use `A...B` to list commits reachable from either side after excluding their shared history.
Use `^B` with one or more starting revisions to exclude commits reachable from `B`.
