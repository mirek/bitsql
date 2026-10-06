# SQL Server 2025 feature audit

Requested 2026-10-06: verify and implement the 2025 additions discussed with the
user. This audit remains open. A smoke test is not proof of complete feature
support. Expected outputs in `harness/corpus/sql2025/` come from the pinned
SQL Server 17.0.5005.3 oracle.

| Requirement | Initial evidence / outstanding work |
| --- | --- |
| Native json, JSON_ARRAYAGG, JSON_OBJECTAGG | Initial smoke passes; existing json3/json4 captures cover much more. Binary DATALENGTH and other roadmap gaps remain. |
| Regex scalar and table functions | REGEXP_REPLACE/REGEXP_COUNT smoke fails: unsupported. Implement all listed functions, metadata, errors, flags and boundaries. |
| Vector type, distance functions, embedding generation, approximate indexes/search | Vector declaration/distance smoke fails: unsupported. External model integration belongs at the host boundary; preview features need separately configured captures. |
| CURRENT_DATE | Initial metadata/date-consistency smoke passes; existing datetime-arithmetic capture also covers it. |
| SUBSTRING optional length | Initially rejected with 174. Two-argument form now passes the expanded differential case, which includes metadata, binary, NULL, negative/zero starts, trailing spaces and argument errors. |
| DATEADD bigint | Implemented with widened intermediate arithmetic; 139 oracle batches pass across numeric argument types, temporal types/scales, range errors, time wrapping and signed extremes. Full gate passed 2026-10-06. |
| String concatenation operator || | Initial smoke fails to parse. Need precedence, NULL, conversions, collation, metadata and truncation captures. |
| Base64 encode/decode | Implemented; 72 batches in `base64.sql` and `base64-padding.sql` pass differential verification, covering metadata, URL-safe mode, NULL, type restrictions, >8000-byte output and malformed-padding error precedence. Full gate passed 2026-10-06. |
| Fuzzy matching | Default oracle rejects EDIT_DISTANCE with 195; bitsql gives 50100. `fuzzy-preview.sql` now captures enabled behavior: SQL_* collation rejected with 9847, Windows collation succeeds. Functions/configuration remain unimplemented; the preview configuration syntax is also a recorded parser gap. |
| Optional parameter plan optimization | Not audited. Correct result sets alone do not prove adaptive plan support. |
| Optimized locking | Not audited. Existing locking support does not prove transaction-ID locking / lock-after-qualification equivalence. |
| ZSTD backup compression | Not audited. SQL acceptance or emulated backup history does not prove a compressed backup artifact. |
| Full/differential backups on secondary replicas | Not audited. Requires real replica topology and corresponding emulator architecture. |
| tempdb resource controls | Not audited. Need concrete configuration, enforcement and error captures. |

The original request includes operational features. Do not silently replace
these with successful no-ops or count an explicit unsupported error as feature
completion. Keep pure core/host boundaries and memory-only architecture visible
when deciding how to implement them.

## Verified checkpoint (2026-10-06)

`scripts/check.sh` passed: 293 MoonBit tests; all-backend core checks;
20,712 client/corpus tests passed, 3 skipped, 0 failed (20,715 total).
This verifies the implemented SUBSTRING/Base64/bigint DATEADD checkpoint,
not the remaining feature requirements above.
