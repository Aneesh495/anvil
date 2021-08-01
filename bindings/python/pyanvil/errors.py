"""
Anvil Version Control Engine
Copyright (c) 2026 Aneesh Krishna
All rights reserved.

Exception classes for Anvil Python bindings.
"""


class AnvilError(Exception):
    """Base exception for all Anvil errors."""
    pass


class RepositoryNotFoundError(AnvilError):
    """Raised when no Anvil repository is found at or above the specified path."""
    pass


class RevisionNotFoundError(AnvilError):
    """Raised when an invalid or nonexistent revision expression is provided."""
    pass


class BranchExistsError(AnvilError):
    """Raised when attempting to create a branch that already exists."""
    pass


class CheckoutError(AnvilError):
    """Raised when a checkout operation cannot be safely performed."""
    pass
