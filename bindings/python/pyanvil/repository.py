"""
Anvil Version Control Engine
Copyright (c) 2026 Aneesh Krishna
All rights reserved.

Object-oriented repository bindings wrapping the native libanvil shared library.
"""

import ctypes
import os
import sys
from typing import Optional
from pyanvil.errors import (
    AnvilError,
    RepositoryNotFoundError,
    RevisionNotFoundError,
    BranchExistsError,
    CheckoutError,
)
from pyanvil.types import RepositoryStatus


def _find_library() -> str:
    """Locate the libanvil dynamic shared library."""
    pkg_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(pkg_dir, "..", "..", ".."))

    candidates = [
        os.path.join(repo_root, "lib", "libanvil.dylib"),
        os.path.join(repo_root, "lib", "libanvil.so"),
        os.path.join(pkg_dir, "libanvil.dylib"),
        os.path.join(pkg_dir, "libanvil.so"),
    ]

    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate

    # Fall back to system dynamic library loader
    if sys.platform == "darwin":
        return "libanvil.dylib"
    return "libanvil.so"


_lib_path = _find_library()
_lib = ctypes.CDLL(_lib_path)

# Function signatures
_lib.anvil_version.restype = ctypes.c_char_p
_lib.anvil_version.argtypes = []

_lib.anvil_repo_open.restype = ctypes.c_void_p
_lib.anvil_repo_open.argtypes = [ctypes.c_char_p]

_lib.anvil_repo_close.restype = None
_lib.anvil_repo_close.argtypes = [ctypes.c_void_p]

_lib.anvil_repo_init.restype = ctypes.c_int
_lib.anvil_repo_init.argtypes = [ctypes.c_char_p, ctypes.c_int]

_lib.anvil_hash_buffer.restype = ctypes.c_int
_lib.anvil_hash_buffer.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]

_lib.anvil_add.restype = ctypes.c_int
_lib.anvil_add.argtypes = [ctypes.c_void_p, ctypes.c_char_p]

_lib.anvil_commit.restype = ctypes.c_int
_lib.anvil_commit.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]

_lib.anvil_status.restype = ctypes.c_int
_lib.anvil_status.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]

_lib.anvil_branch_create.restype = ctypes.c_int
_lib.anvil_branch_create.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]

_lib.anvil_checkout.restype = ctypes.c_int
_lib.anvil_checkout.argtypes = [ctypes.c_void_p, ctypes.c_char_p]

_lib.anvil_rev_parse.restype = ctypes.c_int
_lib.anvil_rev_parse.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]


def version() -> str:
    """Return the underlying Anvil library version string."""
    return _lib.anvil_version().decode("utf-8")


def hash_bytes(data: bytes) -> str:
    """Compute the Git SHA-1 hash for the given byte sequence."""
    buf = ctypes.create_string_buffer(41)
    ret = _lib.anvil_hash_buffer(data, len(data), buf)
    if ret != 0:
        raise AnvilError(f"Failed to hash buffer, code {ret}")
    return buf.value.decode("utf-8")


class Repository:
    """High-level Python wrapper for an Anvil version control repository."""

    def __init__(self, path: Optional[str] = None):
        c_path = path.encode("utf-8") if path else None
        self._handle = _lib.anvil_repo_open(c_path)
        if not self._handle:
            raise RepositoryNotFoundError(f"Not an Anvil repository: {path or os.getcwd()}")
        self._path = path or os.getcwd()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()

    def close(self):
        """Release underlying native repository context."""
        if self._handle:
            _lib.anvil_repo_close(self._handle)
            self._handle = None

    @classmethod
    def init(cls, path: str, bare: bool = False) -> "Repository":
        """Initialize a new repository at path and return open Repository object."""
        c_path = path.encode("utf-8")
        ret = _lib.anvil_repo_init(c_path, 1 if bare else 0)
        if ret != 0:
            raise AnvilError(f"Failed to initialize repository at {path}, code {ret}")
        return cls(path)

    def add(self, file_path: str):
        """Stage a file in the index."""
        if not self._handle:
            raise AnvilError("Repository handle is closed")
        c_path = file_path.encode("utf-8")
        ret = _lib.anvil_add(self._handle, c_path)
        if ret != 0:
            raise AnvilError(f"Failed to add path {file_path}, code {ret}")

    def commit(self, message: str) -> str:
        """Create a new commit with the given commit message."""
        if not self._handle:
            raise AnvilError("Repository handle is closed")
        buf = ctypes.create_string_buffer(41)
        c_msg = message.encode("utf-8")
        ret = _lib.anvil_commit(self._handle, c_msg, buf, 40)
        if ret != 0:
            raise AnvilError(f"Failed to create commit, code {ret}")
        return buf.value.decode("utf-8")

    def status(self) -> RepositoryStatus:
        """Query repository working tree and index status."""
        if not self._handle:
            raise AnvilError("Repository handle is closed")
        is_clean = ctypes.c_int(0)
        staged = ctypes.c_int(0)
        ret = _lib.anvil_status(self._handle, ctypes.byref(is_clean), ctypes.byref(staged))
        if ret != 0:
            raise AnvilError(f"Failed to query repository status, code {ret}")
        return RepositoryStatus(is_clean=bool(is_clean.value), staged_count=staged.value)

    def branch(self, name: str, start_rev: Optional[str] = None):
        """Create a new branch."""
        if not self._handle:
            raise AnvilError("Repository handle is closed")
        c_name = name.encode("utf-8")
        c_rev = start_rev.encode("utf-8") if start_rev else None
        ret = _lib.anvil_branch_create(self._handle, c_name, c_rev)
        if ret == -3:
            raise BranchExistsError(f"Branch {name} already exists")
        if ret != 0:
            raise AnvilError(f"Failed to create branch {name}, code {ret}")

    def checkout(self, target: str):
        """Switch branches or restore files."""
        if not self._handle:
            raise AnvilError("Repository handle is closed")
        c_target = target.encode("utf-8")
        ret = _lib.anvil_checkout(self._handle, c_target)
        if ret != 0:
            raise CheckoutError(f"Failed to checkout {target}, code {ret}")

    def rev_parse(self, rev_expr: str) -> str:
        """Resolve a revision expression to a 40-character hexadecimal SHA."""
        if not self._handle:
            raise AnvilError("Repository handle is closed")
        buf = ctypes.create_string_buffer(41)
        c_expr = rev_expr.encode("utf-8")
        ret = _lib.anvil_rev_parse(self._handle, c_expr, buf, 40)
        if ret != 0:
            raise RevisionNotFoundError(f"Failed to resolve revision {rev_expr}, code {ret}")
        return buf.value.decode("utf-8")
