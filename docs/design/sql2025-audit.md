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
| Native json, JSON_ARRAYAGG, JSON_OBJECTAGG | Existing json3/json4 and construction captures cover type semantics, constructors and aggregates. The 485-case allocation run verifies retained storage, slot ordering, large dictionaries and array widening. Native variable/UPDATE/MERGE `.modify()` now passes 121 registered method cases (126 with adjacent regressions), resolving 49 parser gaps. Typed JSON_VALUE RETURNING and JSON_QUERY WITH ARRAY WRAPPER now pass 180 captured cases, including conversion boundaries, ordered/repeated paths, metadata, computed definitions and error timing. Ordinary native JSON_VALUE/JSON_QUERY last/list accessors and strict selection now pass 48 registered captures (63 with json3/json4 regressions). Native OPENJSON root/WITH accessors now pass 200 registered cases (215 with json3/json4 regressions). Native function/variable/column mutation accessors now pass 300 registered cases, including allocation-dependent errors and batch flow; the combined JSON regression run passes 1,814 cases. Shared large-storage mutation discrepancies remain: conservative container copying and captured wide-array conversion errors. JSON_CONTAINS now passes 255 captured cases for typing, paths, comparisons, table contexts and error flow. JSON indexes now maintain immutable path entries and perform candidate seeks for positive containment/existence predicates. The 204-case focused run covers DDL, catalogs, options, mutation, rollback, native path-existence behavior, indexed error timing and internal catalogs; 58 parser gaps are resolved. Broader index value/range access, option/concurrency/internal-storage details remain under audit; see the JSON reference for evidence and open contracts. |
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
| tempdb resource controls | Initial read-only default-limit/catalog capture in `sql2025/tempdb-governance-catalog.sql`; configuration, classification, page accounting and enforcement remain unimplemented/unverified. See the operational reference for the documented contract and required isolated oracle work. |

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

## JSON_CONTAINS checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,464 MoonBit tests, all-backend core checks,
22,100 client/corpus tests passed, three existing skips and no failures
(22,103 total). The log confirms all 255 JSON_CONTAINS cases and eight
preview-completion cases ran. Focused verification passes 308 cases including
adjacent vector/JSON regressions. Native containment now handles captured
type restrictions, comparisons, collation, list/last/range paths, missing
and empty selections, table filters/updates and runtime error flow.

The final parser check covers 36,735 batches with 65 documented disagreements:
seven existing gaps and 58 exposed by the 57 new JSON index cases. All 57
index cases pass repeat oracle runs; they remain investigative and unregistered
until index implementation. JSON indexes, shared native storage edge cases,
the broader 2025 requirements and publication of a new container remain open.

## Maintained JSON index checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,466 MoonBit tests, all-backend core checks,
22,252 client/corpus tests passed, three existing skips and no failures
(22,255 total). All 152 newly registered JSON index/native-path cases ran.
The parser check covers 37,033 batches with seven existing disagreements;
58 earlier JSON index parser gaps are resolved.
The immutable path index supports candidate seeks with residual evaluation;
two internal tests verify scan equivalence across mutation, rollback, bulk
delete, disabled writes and rebuild. DDL, catalogs, placement/options,
disabled clustered-key dependencies and indexed error timing are captured.

Seventeen further internal-catalog captures remain investigative and
unregistered. Value/range indexing, internal storage, array-search effects,
concurrency and broader dependency/option contracts remain open, alongside
the rest of this audit. No new container has been published.

## JSON index internal catalog checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,466 MoonBit tests, all-backend core checks,
22,304 client/corpus tests passed, three existing skips and no failures
(22,307 total). All 204 registered JSON index/path cases ran, including the
52 internal-catalog cases. Internal objects, columns, keys, statistics,
partition counts, retained disabled state and replacement identity now match
the captures. Physical allocation-unit/page modeling, value/range search,
array-search execution, broader options/dependencies and concurrency remain.

The subsequent extraction captures add 72 investigative cases for typed
JSON_VALUE RETURNING and JSON_QUERY WITH ARRAY WRAPPER. They expose 63 new
parser gaps: the final parser check covers 37,192 batches with 70 documented
disagreements, including seven prior ones. These cases are not registered as
passing and await implementation. The wider 2025 audit and container
publication remain unfinished.

## Typed JSON extraction checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,466 MoonBit tests, all-backend core checks,
22,484 client/corpus tests passed, three existing skips and no failures
(22,487 total). All 180 newly registered extraction cases ran. The focused
combined run passes 639 extraction, containment and index/path cases. Typed
JSON_VALUE and JSON_QUERY WITH ARRAY WRAPPER now handle captured conversions,
ordered/repeated selections, result metadata, computed definitions and errors.

The final parser check covers 37,412 batches with nine documented differences:
seven previous ones and two type-dependent RETURNING syntax diagnostics
handled by the binder. The 112 new ordinary/native entry-point captures
reproduce on a second oracle run but remain investigative and unregistered.
They require distinct extraction, OPENJSON and JSON_MODIFY corrections. The
remaining 2025 requirements and container publication are still unfinished.

## Ordinary native JSON extraction checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,466 MoonBit tests, all-backend core checks,
22,532 client/corpus tests passed, three existing skips and no failures
(22,535 total). All 48 ordinary native extraction cases ran. JSON_VALUE and
JSON_QUERY now preserve ordered/repeated native selections and distinguish
missing, empty, null and multiple results with captured strict diagnostics.

The final parser check passes across 37,676 batches with nine documented
differences. There are 328 investigative native OPENJSON/JSON_MODIFY/method
accessor cases, including 264 added after the previous checkpoint, all verified
by repeat oracle runs. The initial 280-case emulator comparison passes only
seven cases; the rest need correction. Function/method mutation behavior
differs, and OPENJSON root/column selection has distinct error contracts.
These gaps, the wider 2025 audit and container publication remain unfinished.

## Native OPENJSON checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,466 MoonBit tests, all-backend core checks,
22,732 client/corpus tests passed, three existing skips and no failures
(22,735 total). All 200 newly registered OPENJSON cases ran. Root selection,
WITH-column selection, ordered/repeated paths, empty roots and captured
rejection/error precedence now have regression coverage; the focused run
with json3/json4 passes 215 cases.

The final parser check covers 37,791 batches with nine documented differences.
The 240 captured mutation cases remain investigative; 80 missing-parent and
empty-storage cases now establish catchability, retained values and a
provenance-dependent 22020 method diagnostic. All new captures reproduce
against the oracle. Initial read-only tempdb governance catalogs are also
captured and verified, but the emulator rejects the workload-group catalog.
The wider 2025 requirements and publication of a new container remain open.

## Native mutation accessor checkpoint (2026-10-06)

`scripts/check.sh` passed: 1,466 MoonBit tests, all-backend core checks,
23,032 client/corpus tests passed, three existing skips and no failures
(23,035 total). All 300 newly registered mutation cases ran. The combined JSON
run passes 1,814 cases. Native function/variable/column paths now preserve
allocation on no-ops, apply the same effective path to text and storage, and
match captured target-specific diagnostics and batch flow.

The final parser check covers 37,884 batches with nine documented differences.
Further storage captures establish conservative source-key preflight and
operation-specific 13643 behavior. Direct native selection of a corrupted value
reproducibly closes the connection and still lacks a recordable expectation.
The storage gaps, broader 2025 requirements and container publication remain.
