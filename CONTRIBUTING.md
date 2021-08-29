# Contributing to Anvil

Thank you for your interest in contributing to Anvil. As a high-performance systems engineering project, Anvil maintains strict standards for correctness, memory safety, test coverage, and code clarity.

---

## Technical Standards & Guidelines

### 1. Free Pascal Compiler Dialect
- Code is compiled under Free Pascal Compiler 3.2.2+ using `objfpc` mode with long strings enabled:
  ```pascal
  {$mode objfpc}{$H+}
  ```
- All memory allocations must be explicitly freed without relying on garbage collection. Avoid circular references and use `try ... finally` blocks diligently.
- Use explicit 64-bit integer types (`Int64`, `QWord`) for offsets, timestamps, and sizes to ensure multi-gigabyte repository safety.

### 2. Zero Unhandled Exceptions
- Core library routines (`src/odb`, `src/index`, `src/protocol`, `src/lib`) must translate internal exceptions into explicit error codes (`anvil_errors.pas`) when crossing foreign function boundaries or handling external I/O.
- Diagnostics should produce human-readable, precise error messages indicating exact byte offsets or filesystem paths whenever possible.

### 3. Strict Verification & Regression Prevention
- Every new feature or bugfix must be accompanied by comprehensive test cases in `tests/unit` or `tests/integration`.
- When resolving a bug:
  1. Write a reproduction test case that demonstrates the failure.
  2. Implement the minimal, robust engine fix.
  3. Verify that the reproduction test passes.
  4. Retain the test case permanently in the test runner.
- All 286+ test cases in `make test` must pass cleanly (100.0% pass rate) with zero failures.

### 4. Style & Documentation Rules
- DO NOT use em dashes in comments, commit messages, or documentation. Use standard hyphens (`-`), colons, or parentheses.
- Maintain a high comment-to-code ratio with clear function header banners explaining algorithms, time complexity, and parameter contracts.
- Document any platform-specific assumptions (e.g. Darwin vs Linux dylib naming or system linker flags).

---

## Build and Verification Workflow

### Building the Complete Project
```bash
make clean
make all
```

### Running the Test Suite
```bash
make test
```

### Running Performance Benchmarks
```bash
make bench
```

### Running Python Bindings Tests
```bash
make lib
PYTHONPATH=bindings/python python3 -m unittest discover -s bindings/python/tests
```
