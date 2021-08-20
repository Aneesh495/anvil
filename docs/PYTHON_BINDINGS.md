# Python Bindings for Anvil (`pyanvil`)

`pyanvil` provides high-level, type-safe Python bindings for embedding the Anvil version control engine directly into Python applications, scripts, and automation workflows. It communicates with the native `libanvil` dynamic shared library (`libanvil.dylib` on macOS, `libanvil.so` on Linux) through `ctypes`.

---

## 1. Installation and Library Linking

To build `libanvil` from source:
```bash
make lib
```

Ensure the resulting dynamic library resides in `lib/` or along your system dynamic library search path (`LD_LIBRARY_PATH` or `DYLD_LIBRARY_PATH`).

To make `pyanvil` importable in your Python environment:
```bash
export PYTHONPATH="/path/to/anvil/bindings/python:$PYTHONPATH"
```

---

## 2. Quickstart Example

```python
from pyanvil import Repository, hash_bytes

# Compute Git SHA-1 content hash of raw payload bytes
digest = hash_bytes(b"hello world\n")
print(f"Computed SHA-1: {digest}")
# Output: 557db03de997c86a4a028e1ebd3a1ceb225be238

# Initialize a new repository
repo = Repository.init("/tmp/my_repo")

# Create a source file in working tree
with open("/tmp/my_repo/main.py", "w") as f:
    f.write("print('Hello from Anvil')\n")

# Stage files and commit
repo.add(["main.py"])
commit_id = repo.commit(
    message="feat: initial python commit",
    author_name="Aneesh Krishna",
    author_email="aneesh@example.com"
)
print(f"Created commit: {commit_id}")

# Inspect repository status
status = repo.status()
print(f"Active branch: {status.branch}")
print(f"Staged count: {len(status.staged)}")
print(f"Untracked count: {len(status.untracked)}")

# Branching and switching
repo.create_branch("feature/speedup")
repo.checkout("feature/speedup")
```

---

## 3. API Reference

### Module-Level Functions

- `version() -> str`: Returns the semantic version string of the underlying Anvil engine.
- `hash_bytes(data: bytes, algo: str = "sha1") -> str`: Computes the 40-character (SHA-1) or 64-character (SHA-256) hexadecimal content-addressable hash of a byte slice.

### `Repository` Class

#### Lifecycle Management
- `Repository.init(path: str, bare: bool = False) -> Repository`: Initializes a new repository on disk and returns an active instance.
- `Repository.open(path: str) -> Repository`: Opens an existing repository containing an `.anvil` directory.
- `repo.close()`: Frees native handles and unmaps allocated ODB resources. Context manager (`with Repository.open(...) as repo:`) is fully supported.

#### Working Tree and Staging
- `repo.status() -> RepositoryStatus`: Scans working tree against index and returns staged, modified, untracked, and conflicting file paths.
- `repo.add(paths: list[str])`: Stages one or more file paths into `.anvil/index`.
- `repo.commit(message: str, author_name: str, author_email: str) -> str`: Creates a new commit object, writes it to the ODB, advances active branch reference, and returns the 40-character commit ID.

#### Branches and Checkouts
- `repo.create_branch(name: str)`: Creates a new reference under `refs/heads/<name>` pointing to current `HEAD`.
- `repo.checkout(name: str)`: Atomically updates `HEAD`, staging index, and working tree files to match `<name>`.
- `repo.head() -> str`: Resolves the active commit ID referenced by `HEAD`.
- `repo.rev_parse(rev: str) -> str`: Resolves arbitrary revision expressions (e.g. `main~1`, `v1.0.0`) to a full hexadecimal hash.

---

## 4. Error Handling

`pyanvil` translates native C ABI return codes into rich Python exceptions:
- `RepositoryNotFoundError`: Raised when attempting to open a non-existent or invalid repository.
- `RevisionNotFoundError`: Raised when a branch, tag, or commit revision cannot be resolved.
- `BranchExistsError`: Raised when attempting to create a branch that already exists.
- `CheckoutError`: Raised when dirty uncommitted changes prevent a safe working tree checkout.
- `AnvilError`: Base class for all Anvil-specific runtime exceptions.
