"""
Anvil Version Control Engine
Copyright (c) 2026 Aneesh Krishna
All rights reserved.

Data types and status dataclasses for Anvil Python bindings.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class RepositoryStatus:
    is_clean: bool
    staged_count: int


@dataclass(frozen=True)
class CommitInfo:
    hex_id: str
    message: str
