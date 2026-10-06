# SQL Server 2025 feature audit

Requested 2026-10-06: verify and implement the 2025 additions discussed with the
user. This audit remains open. A smoke test is not proof of complete feature
support. Expected outputs in `harness/corpus/sql2025/` come from the pinned
SQL Server 17.0.5005.3 oracle.

Release completion requires publishing a new container version after the full
feature scope and verification pass. The user explicitly authorized GitHub
pushes and container publication on 2026-10-06.

| Requirement | Evidence and outstanding work |
| --- | --- |
| Native json, JSON_ARRAYAGG, JSON_OBJECTAGG | Initial smoke passes; existing json3/json4 captures cover much more. Binary DATALENGTH and other roadmap gaps remain. |
| Regex scalar and table functions | All seven functions are bound and executed. Thirteen SQL corpus files and 271 Unicode boundary/fold cases (21,717 result rows) pass differential verification. Pure VM tests cover ordered captures and error syntax. SQL Server matches Unicode 15.0, not the newer 15.1 reference tables. Partial-byte captures, lone-surrogate patterns and remaining RE2/SQL edge audits are still open; full gate passed 2026-10-06. |
| Vector type, distance functions, embedding generation, approximate indexes/search | Vector declaration/distance smoke fails: unsupported. External model integration belongs at the host boundary; preview features need separately configured captures. |
| CURRENT_DATE | Initial metadata/date-consistency smoke passes; existing datetime-arithmetic capture also covers it. |
| SUBSTRING optional length | Initially rejected with 174. Two-argument form now passes the expanded differential case, which includes metadata, binary, NULL, negative/zero starts, trailing spaces and argument errors. |
| DATEADD bigint | Implemented with widened intermediate arithmetic; 139 oracle batches pass across numeric argument types, temporal types/scales, range errors, time wrapping and signed extremes. Full gate passed 2026-10-06. |
| String concatenation operator `\|\|` | Implemented and passing four differential cases covering precedence, NULL, conversions, fixed binary, computed columns, collation and byte-cap truncation. Full gate passed 2026-10-06. |
| Base64 encode/decode | Implemented; 72 batches in `base64.sql` and `base64-padding.sql` pass differential verification, covering metadata, URL-safe mode, NULL, type restrictions, >8000-byte output and malformed-padding error precedence. Full gate passed 2026-10-06. |
| Fuzzy matching | Disabled preview now produces the captured 195. `fuzzy-preview.sql` now captures enabled behavior: SQL_* collation rejected with 9847, Windows collation succeeds. Preview switch parsing, per-database state and catalog exposure are implemented: full default rows/types, shared session state and transaction rollback pass differential tests. All four functions are implemented and initial/function/Unicode/type-boundary captures plus 256 algorithm pairs pass. Turkish collation is still unsupported; broader normalization and collation verification remain open. Full gate passed 2026-10-06; this does not close the remaining collation gaps. |
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

## Concatenation, preview and fuzzy checkpoint (2026-10-06)

`scripts/check.sh` passed after the normalization changes: 293 MoonBit tests,
all-backend core checks, and 20,729 client/corpus tests passed, 3 pre-existing
skips, 0 failures (20,732 total). The log confirms all 13 newly registered
fuzzy/configuration cases ran. Allowlist entries must include `.sql`; bare case
ids without extensions silently select no file. Focused differential passes
alone are not proof that a case was included in the full gate.

This checkpoint does not complete Turkish collation support, the other open
2025 requirements, or container publication.

## Regex checkpoint (2026-10-06)

`scripts/check.sh` passed: 380 MoonBit tests, all-backend core checks, and
21,013 client/corpus tests passed with 3 pre-existing skips and no failures
(21,016 total). The log confirms all 284 registered regex cases ran: 13 SQL
files plus 271 generated Unicode boundary/fold cases. The regex core has 87
oracle-derived unit tests. This checkpoint retains the open edge audits and
other 2025 requirements above; it does not satisfy container publication.
