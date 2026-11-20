---
title: Anvil documentation
---

# Anvil documentation

Anvil is a Git-compatible version control engine written in Free Pascal. It includes a command-line client, a C ABI library, and Python bindings.

## Start here

Build from source with Free Pascal 3.2.2 or later on macOS or Linux.

```sh
git clone https://github.com/Aneesh495/anvil.git
cd anvil
make anvil lib
make test
```

- [Command-line reference](CLI_REFERENCE.md) covers staging, history, object inspection, and the available flags.
- [Python bindings](PYTHON_BINDINGS.md) shows how to open a repository and invoke Anvil from Python.
- [Repository and build checks](https://github.com/Aneesh495/anvil) links to the source and current Linux test result.

## Internals

- [Architecture](ARCHITECTURE.md) describes the boundaries between the index, object database, and command layer.
- [Internals walkthrough](INTERNALS_WALKTHROUGH.md) follows objects through the engine.
- [Pack format](PACK_FORMAT.md) describes packfile layout and delta resolution.
- [Merge algorithms](MERGE_ALGORITHMS.md) covers tree and line-level merge behavior.
