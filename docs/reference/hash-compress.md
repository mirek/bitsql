# COMPRESS, DECOMPRESS, CHECKSUM

Captured on SQL Server 2025 (msduck `compress-decompress`,
`hashbytes-checksum`; `harness/corpus/conversion/compress`, `checksum`).
Code: `src/core/gzip/*`, `src/core/exec/checksum.mbt`.

## COMPRESS

- Output = gzip member: header `1F8B 08 00 00000000 04 00` (no flags, no
  mtime, XFL 4, OS 0), raw deflate exactly as zlib 1.3.1 produces at level 6
  (windowBits 15, memLevel 8, default strategy: deflate_slow, lazy 16,
  good 8, nice 128, chain 128), CRC-32, ISIZE. Verified byte for byte against
  pseudo-random inputs where levels 4-9 and memLevel 8/9 all differ; bitsql
  ports deflate.c/trees.c (`gzip/deflate.mbt`).
- Empty input → empty varbinary; result varbinary(max), nullable.
- Arguments: character (CP1252 bytes for varchar, UTF-16LE for nvarchar) and
  binary types; others 8116 "... argument 1 of Compress function." Arity 174
  "The Compress function requires 1 argument(s)."

## DECOMPRESS

- Only binary arguments (8116 names `varchar(max)` with its length).
- Empty input → empty; input ending inside the header or the deflate data →
  NULL; wrong magic, method ≠ 8 or an invalid deflate stream → 9826
  "Uncompressed or corrupted data passed as argument to DECOMPRESS builtin.";
  FEXTRA/FNAME/FCOMMENT skipped, FHCRC skipped unchecked, reserved flags
  ignored; the trailer is checked only when all 8 bytes are present (wrong
  CRC-32 or ISIZE → 9826); trailing bytes and further members are ignored; a
  member that decompresses to nothing → NULL.

## CHECKSUM / BINARY_CHECKSUM

Per argument a 32-bit value, combined `h = rotl4(h) ^ value` (rotl4 = rotate
left by 4 bits). Values:

| Type | Value |
| --- | --- |
| typed NULL | 0x7FFFFFFF (an untyped NULL argument of BINARY_CHECKSUM is skipped; of CHECKSUM it is 8116) |
| bit, tinyint, int | the value |
| smallint | zero-extended 16 bits (-1 → 65535) |
| bigint, money | high ^ low 32-bit word |
| smallmoney | int32 units |
| float | high ^ low word of the IEEE bits; 0 and -0 → 0 |
| real | the 32 IEEE bits |
| date | days since 1900-01-01 |
| time | high ^ low word of the 100 ns ticks (any scale) |
| datetime2, datetimeoffset | time value ^ days since 1900 (UTC, offset ignored) |
| datetime | days ^ 1/300 s ticks |
| smalldatetime | days << 16 | minutes |
| uniqueidentifier | rotl4 fold of the 16 storage bytes |
| binary/varbinary | fold of the bytes after dropping trailing 0x00 |
| strings | trailing spaces dropped; BINARY_CHECKSUM folds varchar bytes as signed chars and nvarchar UTF-16 units; CHECKSUM does the same under BIN/BIN2 and folds per-byte sort weights under SQL_Latin1_General_CP1_CI_AS / CS_AS (`exec/checksum_data.mbt`, captured for every byte) |

Not modelled (Emulator error): decimal/numeric (depends only on the
normalized significant digits: 1, 10, 0.1 and -1 hash alike), strings under
Windows collations and nvarchar under SQL collations (sort-key based),
other SQL collations, sql_variant. CHECKSUM(*) covers the FROM columns in
order; text/xml columns are 8116 state 4 per column for CHECKSUM and
skipped by BINARY_CHECKSUM.
