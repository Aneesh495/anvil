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
from pathlib import Path
from tempfile import TemporaryDirectory

from pyanvil import Repository, hash_bytes

# Compute Git SHA-1 content hash of raw payload bytes
digest = hash_bytes(b"hello world\n")
print(f"Computed SHA-1: {digest}")
# Output: 3b18e512dba79e4c8300dd08aeb37f8e728b8dad

# Use a disposable repository and release its native handle before cleanup.
with TemporaryDirectory(prefix="anvil-example-") as directory:
    with Repository.init(directory) as repo:
        Path(directory, "main.py").write_text(
            "print('Hello from Anvil')\n", encoding="utf-8"
        )

        # Stage one path per call, then commit using the native identity.
        repo.add("main.py")
        commit_id = repo.commit("feat: initial python commit")
        print(f"Created commit: {commit_id}")

        status = repo.status()
        print(f"Clean: {status.is_clean}")
        print(f"Staged count: {status.staged_count}")

        repo.branch("feature/speedup")
        repo.checkout("feature/speedup")
        print(f"HEAD: {repo.rev_parse('HEAD')}")
```

---

## 3. API Reference

### Module-Level Functions

- `version() -> str`: Returns the semantic version string of the underlying Anvil engine.
- `hash_bytes(data: bytes) -> str`: Computes the 40-character Git SHA-1 blob ID of a byte slice, including Git's blob header.

### `Repository` Class

#### Lifecycle Management
- `Repository.init(path: str, bare: bool = False) -> Repository`: Initializes a new repository on disk and returns an active instance.
- `Repository(path: Optional[str] = None) -> Repository`: Opens an existing repository, searching upward from `path` or the current directory for `.anvil` or `.git`.
- `repo.close()`: Releases the native repository handle. Context manager (`with Repository(path) as repo:`) is fully supported.

#### Working Tree and Staging
- `repo.status() -> RepositoryStatus`: Returns `is_clean: bool` and `staged_count: int`; the binding does not expose per-file status lists.
- `repo.add(file_path: str)`: Stages one file path into the repository index. Relative paths are resolved from the directory supplied when opening the repository.
- `repo.commit(message: str) -> str`: Creates a commit, advances the active reference, and returns the 40-character commit ID. The binding uses the native library's identity and does not accept author arguments.

#### Branches and Checkouts
- `repo.branch(name: str, start_rev: Optional[str] = None)`: Creates a branch from `start_rev`, defaulting to `HEAD`.
- `repo.checkout(target: str)`: Checks out a branch or revision, refusing conflicting local changes.
- `repo.rev_parse("HEAD") -> str`: Resolves the active commit ID referenced by `HEAD`.
- `repo.rev_parse(rev: str) -> str`: Resolves arbitrary revision expressions (e.g. `main~1`, `v1.0.0`) to a full hexadecimal hash.

---

## 4. Error Handling

`pyanvil` translates native C ABI return codes into rich Python exceptions:
- `RepositoryNotFoundError`: Raised when attempting to open a non-existent or invalid repository.
- `RevisionNotFoundError`: Raised when a branch, tag, or commit revision cannot be resolved.
- `BranchExistsError`: Raised when attempting to create a branch that already exists.
- `CheckoutError`: Raised when dirty uncommitted changes prevent a safe working tree checkout.
- `AnvilError`: Base class for all Anvil-specific runtime exceptions.
