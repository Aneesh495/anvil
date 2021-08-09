# Anvil Packfile and Index v2 Binary Specification

Packfiles are the primary mechanism used by Anvil and Git for compact persistent storage and high-throughput network transmission. This document details the exact binary layout, delta encoding formats, and index lookup structures implemented in Anvil (`src/odb/anvil_pack.pas`, `src/odb/anvil_pack_index.pas`, `src/odb/anvil_pack_writer.pas`).

---

## 1. Packfile Binary Layout (`.pack`)

A packfile is a binary container starting with a 12-byte header, followed by $N$ contiguous indexed objects, terminated by a 20-byte SHA-1 trailer checksum.

```
+-------------------------------------------------------------------+
| 4-byte Signature: 'PACK' (0x5041434B)                             |
+-------------------------------------------------------------------+
| 4-byte Version: 2 (0x00000002) (Big-Endian Network Byte Order)    |
+-------------------------------------------------------------------+
| 4-byte Object Count: N (Big-Endian Network Byte Order)            |
+-------------------------------------------------------------------+
| Object Entry 1:                                                   |
|   Variable-length type and uncompressed size header               |
|   [Optional: Delta base offset or 20-byte base object ID]         |
|   zlib-compressed payload (DEFLATE stream)                        |
+-------------------------------------------------------------------+
| Object Entry 2: ...                                               |
+-------------------------------------------------------------------+
| ...                                                               |
+-------------------------------------------------------------------+
| Object Entry N: ...                                               |
+-------------------------------------------------------------------+
| 20-byte SHA-1 Checksum across all preceding bytes                 |
+-------------------------------------------------------------------+
```

### Object Type and Size Header
The first byte of each entry in a packfile combines the object type and the least-significant 4 bits of its uncompressed size:

```
Bit 7: MSB (1 = more size bytes follow; 0 = final byte of size)
Bit 6-4: Object type identifier
         001 (1) = OBJ_COMMIT
         010 (2) = OBJ_TREE
         011 (3) = OBJ_BLOB
         100 (4) = OBJ_TAG
         110 (6) = OBJ_OFS_DELTA
         111 (7) = OBJ_REF_DELTA
Bit 3-0: Bits 0-3 of uncompressed size
```

Subsequent size bytes provide 7 bits of size per byte:
```
Bit 7: MSB (1 = more size bytes follow; 0 = final byte)
Bit 6-0: Next 7 bits of uncompressed size (shifted by 4, 11, 18, 25, ...)
```

---

## 2. Delta Compression Encoding

Anvil supports both `OBJ_OFS_DELTA` (preferred for local storage efficiency) and `OBJ_REF_DELTA` (used when base objects reside outside the packfile or during thin-pack network transfer).

### OFS_DELTA Header
An `OBJ_OFS_DELTA` entry encodes the negative byte offset from the start of the current object header back to the base object header using a variable-length biased encoding:
1. Each byte provides 7 bits of offset with MSB indicating continuation.
2. In subsequent bytes, the value is shifted and incremented:
   ```pascal
   Offset := (Offset + 1) shl 7 + (B and $7F);
   ```
3. The base object position is computed as: `BaseOffset := CurrentOffset - Offset`.

### Byte-Level Copy/Insert Delta Format
Once decompressed via zlib, the delta payload begins with two variable-length integers:
1. **Source Buffer Length**: Expected size of the base object.
2. **Target Buffer Length**: Resulting size of the hydrated object.

Following the header is a stream of copy and insert operational opcodes:

#### Copy Opcode (`MSB = 1`):
Instructs the engine to copy a slice of bytes from the base object into the output target:
```
Bit 7: 1 (Copy instruction)
Bit 3-0: Bitmask indicating which 4 bytes of source offset follow (Offset LSB to MSB)
Bit 6-4: Bitmask indicating which 2 or 3 bytes of slice length follow (Length LSB to MSB)
```
If length resolves to zero, it defaults to 65,536 bytes (`0x10000`).

#### Insert Opcode (`MSB = 0`):
Instructs the engine to insert literal bytes following the opcode directly into the output target:
```
Bit 7: 0 (Insert instruction)
Bit 6-0: Byte count (1 to 127 bytes)
Followed immediately by N literal bytes.
```

---

## 3. Pack Index Binary Layout (`.idx` v2)

Index v2 files (`anvil_pack_index.pas`) map object hashes directly to their byte offsets within the companion `.pack` file with $O(\log_2(N/256))$ lookup time.

```
+-------------------------------------------------------------------+
| 4-byte Magic: 0xFF744F63 ('\xFFtOc')                              |
+-------------------------------------------------------------------+
| 4-byte Version: 2 (0x00000002)                                    |
+-------------------------------------------------------------------+
| 256-Entry Level-1 Fanout Table (256 * 4 bytes = 1,024 bytes)      |
|   Fanout[i] stores the cumulative count of objects whose SHA-1    |
|   starts with a byte <= i. Fanout[255] equals total object count. |
+-------------------------------------------------------------------+
| Table of Object Names (N * 20 bytes):                             |
|   20-byte SHA-1 hashes sorted lexicographically.                  |
+-------------------------------------------------------------------+
| Table of CRC-32 Values (N * 4 bytes):                             |
|   CRC-32 checksums of each object's compressed wire bytes.        |
+-------------------------------------------------------------------+
| Table of Packfile Offsets (N * 4 bytes):                          |
|   31-bit byte offsets into the .pack file. If bit 31 is set,      |
|   the lower 31 bits index into the 64-bit Large Offset Table.     |
+-------------------------------------------------------------------+
| Optional 64-bit Large Offset Table (M * 8 bytes):                 |
|   Used when packfile size exceeds 2 GB.                           |
+-------------------------------------------------------------------+
| 20-byte SHA-1 of the corresponding .pack file                     |
+-------------------------------------------------------------------+
| 20-byte SHA-1 trailer of all preceding index bytes                |
+-------------------------------------------------------------------+
```

### Accelerated Binary Search Algorithm
To locate object digest $H$ in the index:
1. Extract first byte $B = H[0]$.
2. Determine initial search interval $[Low, High]$ from the fanout table:
   ```pascal
   if B = 0 then Low := 0 else Low := Fanout[B - 1];
   High := Fanout[B] - 1;
   ```
3. Perform standard binary search exclusively within the bounded range $[Low, High]$.
4. Retrieve offset at index $Mid$ from the offset table (dereferencing large 64-bit table if bit 31 is set).

---

## 4. Integrity and Corruption Detection

Anvil enforces rigorous multi-layered verification:
1. **Index Checksum**: Trailer of `.idx` must match SHA-1 over the entire index body.
2. **Packfile Checksum**: Trailer of `.pack` must match SHA-1 over all pack bytes.
3. **Cross-Link Verification**: The 20-byte packfile checksum embedded inside `.idx` must exactly match the `.pack` file trailer.
4. **Per-Object CRC-32**: Reading an object computes the Castagnoli/IEEE CRC-32 over its compressed byte stream and asserts equality against the recorded CRC-32 table entry.
5. **Payload Digest Verification**: Decompressed objects are re-hashed (`type + space + size + \0 + payload`) to verify that their content digest matches their registered object ID.
