# Executor performance

How the executor is made fast without giving up faithfulness, which
techniques from the literature landed (BibTeX: [performance.bib](performance.bib)),
which were evaluated and left out, and how to measure. Numbers are for the
20k-row shapes of `harness/bench/shapes.mjs`.

## Measuring

- `cd harness && npm run bench`: the 24 query/DML shapes against a release
  build (one run each; noisy on a loaded host).
- `npm run bench:compare`: emulator vs real SQL Server containers (README).
- `REPS=30 SHAPE='<regexp>' BITSQL_BIN=… node harness/bench/profile.mjs` (or
  `SQL='q1;; q2'`): repeats queries on one server and prints mean, min and
  exact server CPU (`/proc/<pid>/schedstat`) per query. Compare two binaries
  by interleaving runs and taking the best min; other agents load the host.
- `scripts/profile.sh '<shape regexp>'` or `SQL='...' scripts/profile.sh`:
  where the CPU goes, without perf or ptrace (an LD_PRELOADed SIGPROF
  sampler); `--callers drop_object` names the bitsql code behind runtime
  frames. Sample counts give proportions only: they undercount CPU ~2×.

## Where the time went (2026-10-05)

Profiling the bench put ~45% of executor CPU in memory management: mimalloc
allocation, `moonbit_drop_object` (recursive reference-count release) and
free. Every `Value` constructor with a payload is a heap object, and so is
every tuple, `Option[Int64]` (`Value::as_int64`), row copy and `{ ..ctx }`
record update. Per-row costs were 100–580 ns (`COUNT(*)` over 20k rows:
2.5 ms). Removing per-row allocations was the first lever, algorithms the
second, and the builtin `Map` (insertion-ordered, boxed entries) the third.

## Techniques that landed

| Change | Code | Drawn from |
| --- | --- | --- |
| Expressions compiled once per operator run into closures `(Ctx, Row) -> Value`: result types, collations and operand types resolved once, no per-row `Ctx` copy, built-in calls fed compiled arguments; unspecialized kinds fall back to `eval` | `exec/compile.mbt` | Feeley & Lapalme 1987 [`feeley1987closures`]; Tahboub, Essertel & Rompf, SIGMOD 2018 [`tahboub2018querycompiler`] |
| Push-based streaming: scalar aggregates fold rows as Scan/Filter/Join emit them, joins emit pairs instead of collecting them | `exec/plan.mbt` `stream`, `join_each`; `exec/aggregate_fast.mbt` `stream_aggregate` | Neumann, PVLDB 2011 [`neumann2011compiling`] (produce/consume pipelines) |
| GROUP BY and scalar COUNT/SUM/AVG/MIN/MAX as one pass over per-group accumulators | `exec/aggregate_fast.mbt` | hash aggregation, Graefe 1993 [`graefe1993queryevaluation`] |
| Hash joins on integer keys, one-column grouping and the unnesting key partition through an open-addressing Int64 table (linear probing, unboxed arrays) instead of sorted binary search or the builtin `Map` | `exec/int_table.mbt`, `exec/plan.mbt` `EquiIndex`, `exec/grouping.mbt` | hash join, Graefe 1993 [`graefe1993queryevaluation`]; DuckDB's aggregate hash table (blog, 2022) |
| Correlated integer-key subqueries unnested: the uncorrelated input runs once per statement state, partitioned by key, per-key results reused | `exec/decorrelate.mbt` | Neumann & Kemper, BTW 2015 [`neumann2015unnesting`]; Galindo-Legaria & Joshi, SIGMOD 2001 [`galindolegaria2001subqueries`] |
| ORDER BY on normalized keys: all keys of a row in one integer sequence (NULL tag, order-preserving Int64 halves, terminated linguistic keys, NOT for DESC), one array compare per comparison | `exec/normalized_sort.mbt` | Kuiper & Mühleisen, ICDE 2023 [`kuiper2023sorting`] |
| TOP n ORDER BY through a bounded heap on key values (stable: ties by input position), no sort keys built per row | `exec/top_n.mbt` | standard top-N selection; DuckDB's Top-N boundary comparison |
| Linguistic collation elements packed into one `Int` each and written into reused buffers; exactly sized keys; no per-character structs or tuples | `types/collation_compare.mbt`, `types/sort_key.mbt` | UTS #10 sort keys [`uts10`]; ICU's 32-bit packed collation elements; Kuiper & Mühleisen 2023 [`kuiper2023sorting`] |

Measured but not paper-derived:

- Integer arithmetic in `Int64` when both operands are within ±2^31 (was
  BigInt for every operation); `Value::int64_or` instead of the boxed
  `as_int64`; integers of different types compare in `Int64`.
- Scan cache: a table's materialized rows are kept per physical
  `TableData` (immutable, so identity means equal rows; `Session::source`).
- Window functions sort once by PARTITION BY ++ ORDER BY and reuse that
  permutation as the output order; ROW_NUMBER skips peer groups.
- UPDATE: untouched columns are the same value objects, so FK checks and
  cascades skip them by `physical_equal`; referencing FKs collected once per
  statement; rows replaced in one `PMap::add_all` rebuild.
- Lock grants per (table, session) slot with bulk release; one-allocation
  row keys (decisions.md 2026-10-05).
- Per request: parse cache, precheck memo, the first query reuses the
  prebind plan, seekable UPDATE/DELETE WHERE (decisions.md 2026-10-05).
- Executor-only named built-ins (`NCHAR`, `DATEADD`, …) skip the session's
  catalog function chain (`exec/named_pure.mbt`, guarded by
  `session/named_pure_wbtest.mbt`). Compiled unary `CHAR`/`NCHAR`
  calls also skip the argument array and named-function dispatch, sharing
  the scalar helper with interpreted evaluation. Private fixed tables reuse
  immutable CHAR results and NCHAR's Latin-1 range (256 entries each, sharing
  the strings where their code points agree). Exhaustive UTF-16/code-page
  equivalence and operand-error coverage: `exec/compile_wbtest.mbt` (2026-10-05).

Every change is checked against the full captured corpus; the ones with a
non-obvious equivalence argument have a whitebox test against the code
they short-cut (`top_n_wbtest`, `normalized_sort_wbtest`,
`int_table_wbtest`, `collation_reference_wbtest`, the session test
"unnested correlated subqueries equal the per-row evaluation").

## Evaluated, not landed

- **Lock escalation**: SQL Server escalates when key + page locks reach
  ~6250, and page locks depend on row width, which bitsql does not model
  (decisions.md); not faithful, so not done.
- **Cross-request plan cache** (SQL Server's): the binder reads too many
  session states without one version stamp; needs a catalog generation
  counter first (decisions.md).
- **Vectorized execution** (Boncz, Zukowski & Nes, MonetDB/X100, CIDR 2005):
  with boxed `Value`s most of its benefit is lost; closures took most of
  the interpretation overhead at a fraction of the effort.
- **Adaptive Radix Tree** (Leis, Kemper & Neumann, ICDE 2013): index
  lookups were not where the time went.
- **Hash-partitioned window sort** (group rows by PARTITION BY, sort only
  the distinct keys, then each partition): slower than one normalized sort
  at 5003 partitions of ~4 rows (per-partition arrays and sorts).
- **Hoisting uncorrelated subqueries out of per-row validity checks**: each
  outer row re-checks table stamps (~1 ms on 20k rows); a cheaper check
  needs a write epoch that every write path maintains.

## Results (2026-10-05, best of 3 interleaved runs, ms)

| Shape (20000 rows) | 0.1.5 | 0.1.6 |
| --- | ---: | ---: |
| GROUP BY p (997 groups) | 5.50 | 2.17 |
| GROUP BY v (5003 groups) | 9.96 | 5.40 |
| SELECT DISTINCT v | 8.78 | 5.88 |
| COUNT(DISTINCT v) | 7.07 | 4.93 |
| UNION | 12.46 | 8.25 |
| EXCEPT | 10.16 | 6.04 |
| INTERSECT | 7.50 | 4.92 |
| IN (uncorrelated subquery) | 7.25 | 4.27 |
| NOT IN (uncorrelated subquery) | 6.54 | 2.77 |
| EXISTS (correlated, unindexed) | 17.74 | 5.27 |
| scalar subquery (correlated) | 25.65 | 3.55 |
| scalar subquery (uncorrelated) | 12.98 | 4.89 |
| equi-join | 5.32 | 1.28 |
| ORDER BY v | 6.47 | 1.67 |
| ORDER BY v after a shared non-ASCII prefix | 12.99 | 2.43 |
| ORDER BY accented text | 27.84 | 6.82 |
| ROW_NUMBER over v | 20.36 | 7.81 |
| DELETE WHERE IN (subquery) | 19.08 | 14.36 |
| UPDATE FROM join | 41.26 | 19.88 |
| UPDATE all rows | 37.56 | 18.79 |
| INSERT with FOREIGN KEY | 26.65 | 20.58 |
| DELETE parent rows (FK checked) | 42.12 | 28.11 |
| DELETE with ON DELETE CASCADE | 64.42 | 44.93 |
| MERGE | 41.96 | 26.30 |
| **total** | **477.6** | **251.3** |

Against real SQL Server see the README's benchmark table.

## Single-column grouping (2026-10-05, 0.1.8)

Exact non-integer keys now use an open-addressing array of representative
row positions (`exec/grouping.mbt`). One hash/probe both finds an existing
group and inserts a new one; no per-group Map entry is allocated. The slot
array has power-of-two capacity at least twice the input length (O(n)
scratch space). Integer grouping retains its existing Int64 table, and
inexact or mixed key kinds retain the comparison fallback. Tests in
`grouping_wbtest.mbt` compare text groups with pairwise SQL comparison and
temporal groups with the former Map path, including NULLs and first-occurrence
numbering.

Two interleaved baseline/candidate runs, 30 repetitions per query, 20k rows;
best minimum wall time in ms (release binaries, TLS, no concurrent benchmark):

| Shape | 0.1.7 | 0.1.8 |
| --- | ---: | ---: |
| GROUP BY v (5003 groups) | 5.56 | 5.09 |
| SELECT DISTINCT v | 5.94 | 5.66 |
| COUNT(DISTINCT v) | 4.91 | 4.60 |
| UNION | 8.22 | 7.97 |
| COUNT(DISTINCT CONCAT(N'unique', id)) (20000 distinct strings) | 11.39 | 9.89 |

A raw-string memo in front of the collation-key map was also measured and
rejected: repeated-string queries improved 10–25%, but the all-unique
check regressed from 11.42 to 14.01 ms. Keep a high-cardinality check when
evaluating caches for grouping.

## Accented-text sorting (2026-10-05, 0.1.9)

Profiling the accented ORDER BY shape attributed ~20% of CPU samples to
linguistic comparison and ~19% to generic string-function dispatch. Two
changes address those costs:

- Unequal leading primary weights decide a linguistic comparison before
  building either full element sequence. Four small tables for ASCII,
  Latin-1 and Latin Extended-A are derived from the existing element
  generator (version 0/100, word/string sort). Spaces, ignorables and
  word-sort punctuation cannot decide this way, and equal or unknown
  weights use the existing comparison. The added reference test checks
  2,359,296 pairs, alongside the existing mixed-string tests.
- Compiled CHAR/NCHAR use the scalar helper directly, with shared immutable
  results for CHAR and NCHAR's Latin-1 range (described above). The exhaustive
  character-domain test checks the former implementation's result and
  preserves operand errors; characters outside the cached range still use
  the same conversion and allocation path.

Sequential interleaved release-binary runs, 50 repetitions per shape,
20k rows, best minimum wall time in ms:

| Shape | 0.1.8 | 0.1.9 |
| --- | ---: | ---: |
| ORDER BY v | 1.33 | 1.34 |
| ORDER BY v after a shared non-ASCII prefix | 2.08 | 2.15 |
| ORDER BY accented text | 6.89 | 3.04 |

The collation change alone measured 5.40 ms for accented ORDER BY. Follow-up
checks (one run per binary, 30 repetitions, same query with a different
character function) measured NCHAR(1024 + id % 30), outside the cached
range, at 6.89 → 5.01 ms; CHAR(224 + id % 30) at 6.97 → 3.25 ms.
At 80k rows the original accented shape measured 49.05 → 31.10 ms
(20 repetitions). An initial run overlapped a worker's test compilation and
was discarded; all reported timings were collected with workers idle.

## Integer set membership (2026-10-05, 0.1.10)

Single-column integer EXCEPT/INTERSECT membership now uses `IntTable`,
with a separate NULL flag, rather than allocating an array of sort keys
per row and per probe (`exec/grouping.mbt`, `RowSet`). The original scalar
values are retained in order for noninteger probes: the existing comparison
still determines cross-type equality, conversion errors and early returns.
Text and multicolumn sets retain their previous representation, and result
deduplication/representative selection is unchanged. IN/NOT IN use a separate
`Members` implementation and are not affected by this change.

`grouping_wbtest.mbt` compares the integer path against the general RowSet
implementation, including empty/NULL-only sets, duplicate and mixed integer
constructors, Int64 limits, table growth, and noninteger probes/errors.

Two sequential interleaved release-binary runs, 20k rows, best minimum wall
time in ms (50 repetitions for the standard shapes, 30 for integer EXCEPT):

| Shape | 0.1.9 | 0.1.10 |
| --- | ---: | ---: |
| INTERSECT | 4.93 | 2.31 |
| EXCEPT (text, existing benchmark) | 5.48 | 5.36 |
| SELECT p FROM w EXCEPT SELECT w_id FROM w2 | 5.33 | 2.74 |

At 80k rows, INTERSECT measured 46.37 → 22.68 ms (one run per binary,
20 repetitions). All timings were collected without concurrent builds,
tests or benchmarks.

The validated amd64 container measured INTERSECT at 2.55 ms versus SQL
Server's 4.16 ms; all 24 shapes totalled 257 versus 696 ms (2026-10-06,
Europe/Zurich). UNION measured 12.1 versus 7.92 ms in that run. A follow-up
of two interleaved runs per native release binary (50 repetitions each)
found similar UNION means: 0.1.9 at 8.41/8.54 ms and 0.1.10 at 8.68/8.54 ms.
UNION does not use RowSet; this control did not confirm a regression.
The README retains the original container measurement.

## ROW_NUMBER partition scan (2026-10-06, unreleased)

A direct scan after the unchanged stable sort replaces materialized partition
ranges and unused per-partition index arrays for ROW_NUMBER. It makes the
same adjacent `same_prefix` calls in the same order; intervening rank writes
are local, cannot raise, and do not escape if a later comparison fails.
The white-box test compares against the old partition materialization for
empty/singleton/many rows, NULLs, multiple keys, reversed input positions,
and linguistic/binary collations. Sort keys and expression evaluation are
unchanged, including the distinction between ANSI sort keys and partition
equality.

Two sequential interleaved native release runs at 20k rows, 80 repetitions
each, with no concurrent builds/tests/benchmarks:

| ROW_NUMBER over v | 0.1.10 | Candidate |
| --- | ---: | ---: |
| Mean wall time, run 1 | 8.22 ms | 7.56 ms |
| Mean wall time, run 2 | 8.17 ms | 7.62 ms |
| Minimum wall time, run 1 | 7.75 ms | 7.13 ms |
| Minimum wall time, run 2 | 7.72 ms | 7.13 ms |

Existing window-functions and order-and-types captures give 37/39 on both
baseline and candidate: the same two non-allowlisted failures (SUM window
ordering and COT) remain. Executor unit tests pass (14/14). Full gate passed: 273 MoonBit tests,
20702 client/corpus passes, 3 skips, no failures.

## Streaming exact grouping keys (2026-10-06, 0.1.11, publication pending)

Single-column grouping hashes the exact equality payload with an unboxed
32-bit accumulator and a final avalanche, avoiding the generic Hasher.
It retains sort keys only for representative rows; duplicate keys can be
freed immediately. SortKey equality still checks collisions. Inexact or
mixed kinds discard local partial work and use the existing general path.
No raw-string memo is introduced.

Two sequential interleaved runs of baseline (7f04487), hash-only, and both
changes, 20k rows and 100 repetitions per query. Mean wall time in ms:

| Shape | Baseline runs | Hash-only runs | Combined runs |
| --- | --- | --- | --- |
| GROUP BY v | 5.81 / 5.67 | 5.79 / 5.86 | 5.36 / 5.27 |
| DISTINCT v | 5.91 / 5.82 | 5.69 / 5.90 | 5.52 / 5.46 |
| COUNT(DISTINCT v) | 4.79 / 4.81 | 4.79 / 4.70 | 4.47 / 4.52 |
| UNION | 8.45 / 8.39 | 8.10 / 8.20 | 7.70 / 7.60 |
| COUNT(DISTINCT CONCAT(N'unique', id)) | 10.47 / 10.45 | 10.16 / 10.18 | 9.85 / 10.17 |

The all-unique check improves too; it caught the rejected raw-string memo
in 0.1.8. Executor equivalence tests pass (14/14). The full gate against the exact
amd64 release binary passed: 273 MoonBit tests, 20702 client/corpus passes,
3 skips, no failures. Arm64 smoke passed 571/571.

Container comparison now takes five checked samples per query/DML shape
after one warm-up, reports their median, and saves the raw samples in JSON.
Earlier release comparisons used one timed sample. Every measured execution
now rejects SQL errors; previously only the warm-up was checked. DML shapes
roll back between samples. Old JSON still renders with its original meaning.

The exact 0.1.11 amd64 container comparison (five timed samples per shape)
measured 256 ms total versus SQL Server's 641 ms. UNION was 7.61 versus
7.49 ms, DISTINCT v 6.16 versus 4.40 ms, and ROW_NUMBER 7.87 versus 5.55 ms.
All 48 reported medians were recomputed from the 240 raw samples. These
measurements use a different sampling method from the 0.1.10 table, so the
interleaved native runs above are the before/after evidence. Both database
containers ran sequentially after all builds and validation processes ended.
Images remain local while publication authorization is pending.

## Integer IN membership (2026-10-06, 0.1.12, publication pending)

The IN profile attributed about 31% of sampled execution time to
`Members::contains`. Memoized all-integer subquery sets now also build an
IntTable. Integer probes use it; all other probes retain the existing sorted
values and conversion-aware binary search. Sorting, NULL handling, memo
invalidation, and warning/row-counter replay are unchanged. This applies to
IN/NOT IN, unlike 0.1.10's separate EXCEPT/INTERSECT RowSet specialization.

The new white-box test compares the fast path with binary search for empty
sets, duplicates, mixed integer constructors, Int64 limits, 3000 values,
NULL-present/absent sets, noninteger probes, and errors (15/15 executor tests).
Two sequential interleaved release-binary runs, 20k rows, 120 repetitions:

| Shape | 0.1.11 mean runs | Candidate mean runs | 0.1.11 minimum runs | Candidate minimum runs |
| --- | --- | --- | --- | --- |
| IN | 4.41 / 4.34 ms | 3.16 / 3.20 ms | 4.19 / 4.15 ms | 3.01 / 3.01 ms |
| NOT IN | 2.80 / 2.79 ms | 2.36 / 2.49 ms | 2.73 / 2.71 ms | 2.30 / 2.30 ms |

No builds, tests, or other benchmarks ran concurrently. The exact amd64
release binary passed the full gate: 274 MoonBit tests, 20702 client/corpus
passes, 3 skips, no failures. Arm64 smoke passed 571/571.

The separate uncorrelated scalar-subquery profile still attributes about
30% of inclusive samples to `Session::data_stamp` (table/database lookups
on every outer row). Reducing that cost must preserve detection of table
changes, rollback, session-variable changes, and subquery warning replay;
this membership change deliberately leaves those validity checks intact.

Read-only follow-up: `scope_key` already caches a lowercase database key,
but `db_of` passes it through `Server::get_db`, lowercasing it again on each
stamp probe. A canonical-key lookup is a small next candidate. A stamp cache
could also key on resolved immutable Db identity plus scope/table id, but it
must still resolve `db_of` every time: transaction views, rollback, USE,
temp/table-variable scopes and restored copies can change the resolved Db.
A one-entry cache would miss alternating dependencies in the scalar-subquery
benchmark. Existing variable checks and warning/row-sequence replay must stay.
These are investigation findings, not implemented or measured optimizations.

The exact 0.1.12 amd64 container measured IN at 3.11 ms versus SQL Server's
4.88 ms and NOT IN at 2.39 versus 3.12 ms; the 24 shape medians totalled
247 versus 669 ms. The raw 240 samples reproduce all 48 reported medians.
The first comparison attempt failed before measurement on a transient port
47340 bind conflict; the successful retry ran after confirming the port was
free and no competing benchmark process was active.

The separate 1000-point-select container workload measured 187 versus
159 ms. A follow-up of two interleaved native runs per binary, ten batches
of 1000 reads each, found baseline wall medians 106.20/109.42 ms and candidate
105.90/106.80 ms; server CPU medians 37.26/36.34 versus 35.50/35.31 ms.
This does not confirm a persistent regression. The README retains the actual
container result. Publication remains pending destination authorization.

## Canonical database-key lookup (2026-10-06, candidate)

`scope_key` already returns a lowercase key. `db_of` and `tx_part` now call
an internal canonical-key helper; arbitrary-name `get_db` callers still
lowercase their input. The missing-database fallback and table-stamp checks
are unchanged. Session tests pass (36/36).

Two sequential interleaved native runs, 20k rows, 120 repetitions per shape:

| Shape | 0.1.12 mean runs | Candidate mean runs |
| --- | --- | --- |
| IN | 3.22 / 3.20 ms | 3.15 / 3.23 ms |
| NOT IN | 2.41 / 2.39 ms | 2.32 / 2.33 ms |
| EXISTS | 5.61 / 5.46 ms | 5.54 / 5.58 ms |
| Scalar correlated | 3.49 / 3.50 ms | 3.45 / 3.52 ms |
| Scalar uncorrelated | 4.87 / 4.90 ms | 4.81 / 4.85 ms |

The gain is small (roughly 1–3% on uncorrelated paths), with other changes
within timing variability. Full gate remains pending. The next candidate is
a bounded stamp reader scoped to an execution context, resolving `db_of`
each time and caching table stamps only while the immutable Db identity
matches. Context scope would avoid keeping an old whole-database snapshot
alive for a session's lifetime. It needs mutation/rollback/cross-database
validation before implementation can be accepted.

## Context-scoped stamp reader (2026-10-06, 0.1.13)

Each execution context now owns a bounded table-stamp reader (at most 64
entries). Every probe resolves `db_of` normally. If scope or immutable Db
identity changes, cached entries are cleared; otherwise integer table-id
lookups avoid the table PMap traversal and composite-key stamp lookup.
Scope 2 and missing tables retain None. Misses use the original data_stamp.
Both normal and RPC frame contexts use the reader. Variable validity checks,
warning replay, row-counter replay, and memo clearing remain unchanged.

A stamp identifies one immutable TableData. Reusing an older stamp after
restoring the identical Db is safe even if another context observed an
intervening write: that stamp still names the same data. The original
stamp allocator remains monotonic and never assigns a number to other data.
The reader dies with its execution context, avoiding session-lifetime
retention of an old whole-database snapshot.

`stamp_wbtest.mbt` covers repeated probes, unrelated and target writes,
savepoint/full rollback, truncate/drop, absent and catalog tables, switching
between databases sharing object IDs, temporary/table-variable scopes, and
a second reader observing a write before an identical Db is restored,
numeric cross-database scopes, and eviction beyond the 64-table bound.
Session tests pass (37/37); full release gate pending.

Two interleaved runs per variant, 20k rows, 150 repetitions, no concurrent
builds/tests/benchmarks. Mean wall time in ms:

| Shape | 0.1.12 | Canonical key only | Key + stamp reader |
| --- | --- | --- | --- |
| IN | 3.21 / 3.09 | 3.09 / 3.09 | 2.80 / 2.87 |
| NOT IN | 2.39 / 2.35 | 2.35 / 2.33 | 1.91 / 1.92 |
| EXISTS | 5.40 / 5.35 | 5.41 / 5.35 | 5.02 / 5.05 |
| Scalar correlated | 3.47 / 3.41 | 3.45 / 3.41 | 3.09 / 3.16 |
| Scalar uncorrelated | 4.93 / 4.93 | 4.89 / 4.84 | 4.11 / 4.15 |

ROW_NUMBER follow-up design (implemented in the 0.1.15 candidate below): retain each
normalized key's offset after its partition columns, stable-sort the existing
position array, and compare adjacent normalized prefixes for boundaries.
This could avoid re-comparing linguistic values and rebuilding keyed tuples
and permutations. Guard every partition key with `!ansi_key`: varchar sorting
can use ANSI semantics while current partition equality uses ansi=false.
On normalization failure, reuse the already evaluated values in the old path,
preserving expression counts and comparison errors. Test ranks AND output
permutations, NULLs/ties/DESC/multiple keys, linguistic equivalence and binary
fallback, mixed kinds and errors. Measure normal, long shared-prefix, unique,
and single-partition inputs. Do not retry the rejected hash-partitioned sort.

The first eager reader passed the exact-container gate (275 MoonBit tests,
20702 client/corpus passes, 3 skips, arm64 571/571) and measured scalar
uncorrelated 4.25 vs SQL Server 4.31 ms in the container. It is not the final
0.1.13 candidate: subsequent write controls exposed context-allocation cost.
Two interleaved native runs, 40 repetitions, mean ms:

| Shape | 0.1.12 | Eager stamp reader |
| --- | --- | --- |
| DELETE WHERE IN | 14.67 / 13.81 | 15.35 / 15.06 |
| UPDATE all rows | 19.58 / 19.06 | 20.15 / 20.18 |
| INSERT with FK | 21.59 / 21.40 | 21.71 / 22.01 |
| MERGE | 26.47 / 26.83 | 28.70 / 28.53 |

The current revision allocates its cache state and map only on the first
stamp probe, using one optional captured state instead of eagerly creating
a map and separate mutable scope/database captures per context. Read/write
remeasurement and a new full release gate are required. Eager comparison
artifacts have an `-eager` suffix so they cannot be mistaken for final results.

Lazy allocation removed most eager write overhead, but DELETE WHERE IN still
regressed (baseline means 14.01/13.57 ms, lazy 14.82/15.11 ms): `dml_scan`
created a new context per predicate row, preventing cache reuse and repeating
lookup on every cold miss. It now creates one context after materializing the
source and uses `with_row` for each predicate. The frame's variable array,
live session callbacks, evaluation order and error handling are unchanged.

Combined lazy reader + shared DML predicate context, two interleaved native
runs, 60 repetitions per shape, mean ms (no concurrent work):

| Shape | 0.1.12 runs | Revised candidate runs |
| --- | --- | --- |
| IN | 3.18 / 3.26 | 2.85 / 3.13 |
| NOT IN | 2.36 / 2.38 | 1.93 / 2.13 |
| EXISTS | 5.46 / 5.51 | 5.05 / 5.61 |
| Scalar correlated | 3.53 / 3.54 | 3.21 / 3.24 |
| Scalar uncorrelated | 5.04 / 5.01 | 4.55 / 4.23 |
| DELETE WHERE IN | 13.07 / 13.52 | 11.17 / 11.18 |
| UPDATE all rows | 18.88 / 19.35 | 19.25 / 19.43 |
| INSERT with FK | 20.62 / 20.92 | 21.02 / 21.63 |
| MERGE | 26.50 / 27.16 | 27.96 / 27.43 |

DELETE now improves about 15–17%. Subquery gains remain, with variability
in EXISTS. Small write overhead remains in these controls; keep it visible
when assessing the fresh container comparison. All 37 session tests pass;
new exact container builds, full gate and comparison are pending.

Final revised 0.1.13 validation: exact amd64 release binary passed the full
gate (275 MoonBit tests, 20702 client/corpus passes, 3 skips, no failures);
arm64 smoke passed 571/571. The container comparison ran after all builds,
tests and worker activity ended. All 48 medians were verified from 240 raw
samples. Total shape medians: 244 ms vs SQL Server 668 ms. Scalar uncorrelated:
4.26 vs 4.65 ms; NOT IN: 1.86 vs 3.17 ms; DELETE WHERE IN: 11.2 vs 102 ms;
MERGE: 27.0 vs 31.6 ms. Text grouping and ROW_NUMBER remain clearly slower;
EXISTS is 5.05 vs 4.90 ms. README reflects this final revised comparison,
not the eager variant. Published after explicit registry authorization on
2026-10-06: `0.1.13`, `0.1` and `latest` have identical amd64 + arm64
manifest lists, digest
`sha256:0949be20d29855ddb5abbd74e42bbc8535a1fe88243b88d946e8cc352f936a0b`.


## Normalized window prefixes and adaptive grouping (2026-10-06, 0.1.15 candidate)

ROW_NUMBER reuses the normalized partition prefix after the same stable sort,
without reconstructing keyed tuples or comparing linguistic partition values
again. ANSI partition keys keep the existing path; an encoding failure reuses
the evaluated values in the general comparator. Tests compare ranks and output
permutations, expression evaluation traces, NULLs, ties, multiple keys, DESC,
linguistic equivalence, binary/ANSI and mixed-type/error fallbacks.

Two interleaved native runs (100 repetitions, 20k rows) measured ROW_NUMBER
7.53/7.29 ms before versus 6.76/6.76 ms after. Ordinary ORDER BY controls stayed
stable. With 60 repetitions, all-unique partitions improved 13.62/13.55 to
12.97/12.49 ms and a single partition 7.14/7.03 to 6.65/6.53 ms. Long prefixes,
ANSI, binary and decimal fallback controls were approximately unchanged.
Evidence: `_build/window-prefix-bench-0.1.14.txt` and
`_build/window-prefix-controls-0.1.14.txt`.

Single-column exact text grouping now optionally caches raw-string group ids
once observed duplicate groups justify it. All-unique input never allocates the
cache. Activation checks powers of two from 1024 rows, requires fewer than 75%
as many groups as rows, and requires at least as much input remaining as was
read. A 1024-probe interval with fewer than 128 hits disables the cache if the
distribution changes. Cache misses retain the canonical collation-key path;
first-appearance group numbering and comparison errors remain unchanged.
Expanded pairwise SQL-comparison tests cover 12k rows across linguistic and
binary collations, ANSI modes and NULLs; separate tests cover unique input,
distribution changes, the 5003-group workload and a late mixed-type error.

The first version allowed late activation, regressing 12k distinct values in
20k rows from 9.47/9.28 to 10.75/10.55 ms. Requiring half the input to remain
removed that regression. Final controlled native results (mean ms; grouping
baseline already includes the window change):

| Shape | Before | After |
| --- | ---: | ---: |
| GROUP BY v | 5.35 | 5.12 |
| DISTINCT v | 5.61 | 5.32 |
| COUNT(DISTINCT v) | 4.46 | 4.29 |
| UNION | 7.72 | 6.36 |
| All-unique text | 9.94 / 9.93 | 9.90 / 10.06 |
| Repeats then unique | 10.21 / 10.25 | 10.05 / 10.32 |
| 12k distinct values | 9.96 / 9.52 | 9.44 / 9.36 |
| Long repeated text | 20.37 / 20.49 | 14.36 / 14.61 |
| Raw-unique trailing-space equivalents | 65.37 / 66.58 | 68.35 / 67.97 |

The last control exposes a small cost when SQL-equal strings do not repeat
exactly (roughly 2–4% here); it is retained as a tradeoff, not called a win.
Integer grouping, EXCEPT and the window optimization stayed stable. Timings ran
sequentially with no concurrent builds/tests/benchmarks. Evidence:
`_build/adaptive-group-final-bench.txt` and
`_build/adaptive-group-final-controls.txt`. The profile helper now rejects SQL
errors during setup, warm-up and every timed run; an invalid-column probe
confirmed nonzero exit. Full release validation and container comparison pending.
