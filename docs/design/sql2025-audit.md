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
| Native json, JSON_ARRAYAGG, JSON_OBJECTAGG | Existing json3/json4 and construction captures cover type semantics, constructors and aggregates. The 485-case allocation run verifies retained storage, slot ordering, large dictionaries and array widening. Native variable/UPDATE/MERGE `.modify()` now passes 121 registered method cases (126 with adjacent regressions), resolving 49 parser gaps. Shared large-storage mutation discrepancies remain: conservative container copying and captured wide-array conversion errors. JSON_CONTAINS and JSON indexes remain unimplemented; see the JSON reference for evidence and open contracts. |
| Regex scalar and table functions | All seven functions are bound and executed. Thirteen SQL corpus files and 271 Unicode boundary/fold cases (21,717 result rows) pass differential verification. Pure VM tests cover ordered captures and error syntax. SQL Server matches Unicode 15.0, not the newer 15.1 reference tables. Scalar/SPLIT byte decoding, lone-surrogate normalization, BOM preservation and flag-type checks now pass all 351 captured regex cases. Fourteen MATCHES transport-failure cases lack expectations and remain open, along with remaining RE2/SQL edge audits; the previous checkpoint passed the full gate 2026-10-06. |
| Vector type, distance functions, embedding generation, approximate indexes/search | Native float32 and preview float16 storage, JSON conversion, TDS 7.4 fallback, catalogs, properties and base-specific distance kernels are implemented. Float32 norms/normalization work; float16 receives SQL Server’s captured 42246 rejection. All 150 vector cases pass focused verification, including declaration diagnostics, preview transitions and maximum dimensions. Broader conversion/operator edges, embedding/model integration and approximate indexes/search remain open. External integration belongs at the host boundary. Full gate passed 2026-10-06. |
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

## Float32 vector checkpoint (2026-10-06)

`scripts/check.sh` passed after the common-type corrections: 809 MoonBit tests,
all-backend core checks, and 21,123 client/corpus tests passed with three
pre-existing skips and no failures (21,126 total). All 110 registered vector
cases ran. The 429 generated vector core tests derive their expectations from
SQL Server captures. New CASE/COALESCE/UNION captures caught a false-positive
conversion before this checkpoint: vector/string combinations choose a string
capacity based on the vector's native bytes and can raise truncation error 42211.

The unregistered descriptor/contract cases and new float16 captures retain the
open work. Float16 NORM/NORMALIZE are rejected by SQL Server itself; float16
distance requires a distinct accumulation layout. Details and evidence are in
[the vector reference](../reference/vector.md). This checkpoint does not complete
the 2025 audit or publish a new container.

## Float16 vector checkpoint (2026-10-06)

`scripts/check.sh` passed after moving the additional failed-declaration
reference diagnostic into the session layer: 1,108 MoonBit tests, all-backend
core checks, and 21,163 client/corpus tests passed with three pre-existing skips
and no failures (21,166 total). All 150 registered vector cases ran. The parser
continues to report syntax diagnostics only. The vector core has 728 generated
oracle-derived tests, including the 288 float16 distance pairs.

The release script now includes all registered vector cases in its ARM64 smoke.
No new container is published at this checkpoint. The broader SQL/JSON, regex,
fuzzy, vector search/embedding and operational requirements remain open.

## Regex encoding checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,108 MoonBit tests, all-backend core checks,
21,230 client/corpus tests passed, three pre-existing skips and no failures
(21,233 total). All 351 registered regex cases ran. Scalar/SPLIT byte decoding,
raw-byte replacement assembly, BOM preservation, lone-surrogate handling and
flag-type validation now have regression coverage.

The parser check covers 35,882 batches with 50 known differences: seven prior
ones and 43 newly captured native JSON column-method syntax gaps. These are
unfinished functionality, not waived regressions. Additional TOP(1) MATCHES
captures and native JSON mutation captures remain investigative and unregistered.
No new container is published; this checkpoint does not complete the audit.

## Native JSON construction-storage checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,344 MoonBit tests, all-backend core checks,
21,468 client/corpus tests passed, three pre-existing skips and no failures
(21,471 total). All 238 newly registered cases ran: 236 size captures,
`json-constructed-storage.sql`, and `json4/type-datalength.sql`. The parser
check covers 35,897 batches with the same 50 known differences.

Native JSON now carries canonical text and storage provenance. Fresh values
report the captured binary size; native assignment preserves provenance and
JSON_QUERY rebuilds storage. JSON_MODIFY allocation is still unknown and its
DATALENGTH explicitly rejects rather than reporting a rebuilt size. Native
modify, the other open 2025 requirements, and container publication remain.

## Native JSON allocation checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,411 MoonBit tests, all-backend core checks,
21,629 client/corpus tests passed, three pre-existing skips and no failures
(21,632 total). All 161 newly registered allocation/slot/path cases ran.
The immutable allocation model preserves mutation history, assignment copies,
and transaction snapshots. The subsequent large-storage captures expose
remaining size discrepancies documented in the JSON reference; they are
investigative and unregistered. Native modify contracts add six known parser
gaps to the previous 50. These gaps and the wider feature audit remain open.
No new container has been published.

## Native JSON wide-storage checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,464 MoonBit tests, all-backend core checks,
21,716 client/corpus tests passed, three pre-existing skips and no failures
(21,719 total). All 87 newly registered large-storage cases ran. The combined
focused allocation run passes 485 cases; 356 storage unit tests derive their
expectations from oracle captures. The subsequent parser check includes all
36,237 batches, retaining the same 56 known syntax gaps. Four large object cases previously missing
expectations now have successful captures with a longer request timeout.

The allocator models dictionary-index materialization, document-wide format
changes and rebuilding live storage during widening. Conservative container
copying and captured wide-array corruption behavior still have discrepancies;
new investigative cases document the limits. Native modify syntax/execution,
the rest of the 2025 audit, and a new published container remain outstanding.

## Native JSON mutator checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,464 MoonBit tests and 21,837 client/corpus
tests passed, three existing skips and no failures (21,840 total). All 121
newly registered native method cases ran. Variables, UPDATE and MERGE now
execute native JSON `.modify()` with captured binding, runtime error and
completion behavior. The final parser check covers 36,451 batches with seven
known disagreements; 49 native column-method parser gaps are resolved.

Four investigative JSON_CONTAINS fixtures capture 167 cases, including native
target typing, NULL precedence, collation, comparison modes and navigation.
They remain unregistered pending implementation. Shared large JSON storage
discrepancies, the remaining 2025 audit and container publication remain open.
