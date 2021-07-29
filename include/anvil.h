/**
 * Anvil Version Control Engine
 * Copyright (c) 2026 Aneesh Krishna
 * All rights reserved.
 *
 * C ABI foreign function interface (FFI) declarations.
 */

#ifndef ANVIL_H
#define ANVIL_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Return library version string (e.g. "1.0.0").
 */
const char* anvil_version(void);

/**
 * Open an existing Anvil repository.
 * If path is NULL, searches upward from the current working directory.
 * Returns an opaque repository handle, or NULL on error.
 */
void* anvil_repo_open(const char* path);

/**
 * Close and release resources associated with an open repository handle.
 */
void anvil_repo_close(void* repo);

/**
 * Initialize a new Anvil repository at the given path.
 * If path is NULL, initializes in current working directory.
 * Set is_bare non-zero for bare repository layout.
 * Returns 0 on success, negative error code on failure.
 */
int anvil_repo_init(const char* path, int is_bare);

/**
 * Compute the canonical Git SHA-1 object ID of raw buffer data.
 * out_hex must point to a buffer of at least 41 bytes (40 hex digits + null terminator).
 * Returns 0 on success.
 */
int anvil_hash_buffer(const void* data, int len, char* out_hex);

/**
 * Add a working tree file to the staging index.
 * Returns 0 on success, negative error code on failure.
 */
int anvil_add(void* repo, const char* file_path);

/**
 * Create a new commit from the current index state.
 * out_commit_hex: buffer of at least 41 bytes to receive new commit hex ID (optional, can be NULL).
 * Returns 0 on success, negative error code on failure.
 */
int anvil_commit(void* repo, const char* msg, char* out_commit_hex, int max_len);

/**
 * Query repository working tree and index status.
 * out_is_clean: set to 1 if clean, 0 if modified/untracked files exist.
 * out_staged_count: number of files currently staged in index.
 * Returns 0 on success.
 */
int anvil_status(void* repo, int* out_is_clean, int* out_staged_count);

/**
 * Create a new branch pointing to the specified start revision (or HEAD if start_rev is NULL).
 * Returns 0 on success, negative on error.
 */
int anvil_branch_create(void* repo, const char* name, const char* start_rev);

/**
 * Switch branches or checkout a commit target.
 * Returns 0 on success, negative on error.
 */
int anvil_checkout(void* repo, const char* target);

/**
 * Resolve a revision expression (e.g. "HEAD", "HEAD~1", "main") to a 40-digit hexadecimal SHA.
 * out_hex must point to a buffer of at least 41 bytes.
 * Returns 0 on success, negative on error.
 */
int anvil_rev_parse(void* repo, const char* rev_expr, char* out_hex, int max_len);

#ifdef __cplusplus
}
#endif

#endif /* ANVIL_H */
