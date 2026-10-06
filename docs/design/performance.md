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

## Streaming exact grouping keys (2026-10-06, 0.1.11 local build)

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
The 0.1.11 tags were not published separately. These changes shipped
cumulatively in 0.1.13 after explicit registry authorization.

## Integer IN membership (2026-10-06, 0.1.12 local build)

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
container result. The 0.1.12 tags were not published separately; these
changes shipped cumulatively in 0.1.13.

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

ROW_NUMBER follow-up design (implemented in 0.1.15 below): retain each
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


## Normalized window prefixes and adaptive grouping (2026-10-06, 0.1.15)

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
confirmed nonzero exit. Final release results follow.


Final release validation: the exact amd64 binary passed `scripts/check.sh`
(280 MoonBit tests, 20703 client/corpus passes, three skips, no failures).
The exact arm64 binary passed 572/572 smoke cases including the 0.1.14 JSON
compatibility case. After builds, tests and worker activity stopped, the isolated
container comparison measured 243 ms vs SQL Server 669 ms across the 24 shapes.
All 48 medians were verified against 240 raw samples. GROUP BY v: 5.56 vs
5.05 ms; DISTINCT v: 5.71 vs 4.54; COUNT(DISTINCT v): 4.30 vs 3.89; UNION:
6.76 vs 7.96; ROW_NUMBER: 7.03 vs 5.97; EXISTS: 5.12 vs 4.93. All other
shape medians beat SQL Server, though accented ORDER BY is near parity.
Four clear gaps plus the near-tied EXISTS remain; the optimization goal is not
complete. The total is nearly unchanged from 0.1.13 because write timings
dominate it; individual targeted gains should not be presented as a large
end-to-end improvement. README tables reflect this exact container run.
Evidence: `harness/out/bench-compare-0.1.15.json`, `_build/bench-0.1.15.txt`,
`_build/check-0.1.15.log`, `_build/arm64-0.1.15.log`.


Published 0.1.15 from revision `56cf74a7e12627de8f30fe87827c372d6de5a634`.
The tested filesystem layers were unchanged when revision labels were added.
`0.1.15`, `0.1` and `latest` have identical amd64 + arm64 registry manifests,
digest `sha256:0681ff73eb82e316b7b3a02c46c6c8de67c63cc3cc70a714cc0f3204730d5444`.
The amd64 registry layers total 12.4909 MiB compressed (README rounds to 12.5).


## Flat count and grouping inputs (2026-10-06, 0.1.16)

COUNT/COUNT_BIG with an argument formerly retained `(value, row)` tuples,
constructed one-element key rows for DISTINCT, and built representative tuples
only to take their length. The count-specific path now evaluates arguments
once in the same order, records NULL elimination as before, retains only values
when DISTINCT is needed, and returns the grouping cardinality. Inexact/mixed
key kinds use the same general grouping comparison path on those values,
without reevaluating expressions or retrying exact-key normalization.

The single-column exact grouping helper takes a flat value array. Other
single-column GROUP BY/DISTINCT callers adapt their rows once; measurements
show the contiguous-value traversal pays for that temporary pointer array.
The existing canonical grouping rules, adaptive raw-string cache and group
numbering remain unchanged. Equivalence tests compare counts, NULL-warning
state, expression-call traces and errors against `agg_inputs`, including
empty/all-NULL inputs, numeric/temporal/binary/variant values, mixed-type errors,
linguistic and binary collations, ANSI modes, and large repeated text inputs.

Two sequential interleaved native runs (100 repetitions, 20k rows, mean ms):

| Shape | 0.1.15 baseline | Candidate |
| --- | ---: | ---: |
| GROUP BY p | 1.78 / 1.75 | 1.52 / 1.54 |
| GROUP BY v | 5.15 / 5.06 | 4.61 / 4.91 |
| DISTINCT v | 5.38 / 5.26 | 4.92 / 4.91 |
| COUNT(DISTINCT v) | 4.20 / 4.18 | 3.18 / 3.22 |
| UNION | 6.31 / 6.24 | 5.83 / 5.76 |
| EXCEPT | 5.85 / 5.84 | 5.79 / 5.79 |
| INTERSECT | 2.38 / 2.29 | 2.26 / 2.21 |

Controls (60 repetitions): all-unique COUNT DISTINCT improved 10.01/9.77 to
9.07/9.19 ms; grouped COUNT DISTINCT 5.05/4.90 to 4.13/4.20; nullable COUNT
DISTINCT 4.84/4.75 to 3.81/3.85. Decimal, float and ANSI fallback controls
improved slightly, and window COUNT stayed approximately unchanged. All timed
queries checked for SQL errors; no builds, tests or benchmarks overlapped.
Evidence: `_build/flat-count-bench.txt`, `_build/flat-count-controls.txt`.
Final release validation and container results follow.


The exact amd64 release binary passed the full gate: 281 MoonBit tests,
20703 client/corpus passes, three skips and no failures. Arm64 passed 572/572
smoke cases. The first benchmark attempt failed to bind 47340 before collecting
any timings. After confirming the process exited and both ports/container names
were free, the isolated retry completed. All 48 medians match their 240 raw
samples. COUNT DISTINCT now beats SQL Server (3.31 vs 3.92 ms), as does UNION
(5.93 vs 8.15 ms). Total shape medians: 234 vs 672 ms, about 2.9x. This is the
observed complete-workload result, not a claim that all write timing changes
came from this optimization.

Three clear gaps remain: GROUP BY v 5.41 vs 5.03 ms, DISTINCT v 5.59 vs 4.63,
and ROW_NUMBER 7.19 vs 6.07. EXISTS is effectively tied (4.94 vs 4.91 ms).
The full optimization goal remains open. README now reflects this run.
Evidence: `harness/out/bench-compare-0.1.16.json`, `_build/bench-0.1.16.txt`,
`_build/check-0.1.16.log`, `_build/arm64-0.1.16.log`.


Published 0.1.16 from revision `d8f8fa7f3a458239d5272806d340e5210b04677c`.
The revision-label update preserved the tested filesystem layers. Tags
`0.1.16`, `0.1` and `latest` have identical amd64 + arm64 registry manifests,
digest `sha256:31799811a93e9b131fdf58a5b8e5ed5df01bbbf175d29b1258206345ea35d09b`.
The amd64 compressed registry layers total 12.4913 MiB.


## Direct window keys and prefix comparisons (2026-10-06, 0.1.17)

ROW_NUMBER with direct column keys now normalizes the source rows through
column ordinals, avoiding a key-value array and compiled-column calls per row.
Only `Col` expressions qualify; other expressions retain their evaluation path.
The ANSI-partition guard remains. If direct normalization is unavailable, the
pure column reads are materialized and the existing general comparator runs,
without retrying normalization. Unit comparisons cover ranks and permutations,
reordered keys, unused payload columns, NULLs, collations, decimal/binary/ANSI
fallbacks and mixed-type errors. Existing expression-trace tests still pass.

Window rows are assembled directly in the already-decided output order. This
removes an intermediate pointer array and preserves call evaluation order and
the existing last-eligible-call ordering rule. It adds no measurable gain to
the main ROW_NUMBER query by itself; unpartitioned windows and window aggregates
showed a small 1–2% reduction. Final appended rows are also checked against the
materialized-key reference in the new tests.

Normalized sorts compute the exact common prefix of all encoded keys once,
then omit those equal leading elements from comparisons. This preserves
lexicographic ordering and stability, including variable-length keys. Tests
compare all pairs and sorted permutations with full comparisons for empty,
identical, negative, variable-length and long-prefix keys. Short-key gains were
not clear in isolation. Long-prefix window/full-sort controls improved about
5–7% (30.64/30.66 to 29.06/28.92 ms, and 26.69/26.87 to 25.42/25.07 ms).
Already-sorted and identical-key controls stayed stable. An invalid constant
ORDER BY control was rejected before measurement; the complete rerun uses
`ORDER BY id-id`, not the partial first run.

Final combined native comparison, two interleaved runs, 100 repetitions, 20k
rows (mean ms):

| Shape | 0.1.16 | Candidate |
| --- | ---: | ---: |
| ROW_NUMBER over v | 6.78 / 6.87 | 5.87 / 6.00 |
| GROUP BY v | 4.99 / 4.95 | 4.80 / 4.96 |
| DISTINCT v | 5.31 / 5.29 | 5.07 / 5.06 |
| COUNT(DISTINCT v) | 3.20 / 3.35 | 3.21 / 3.22 |
| UNION | 6.06 / 6.14 | 6.04 / 6.03 |
| ORDER BY v (TOP 10) | 1.62 / 1.64 | 1.66 / 1.64 |
| ORDER BY accented text (TOP 10) | 3.10 / 3.13 | 3.13 / 3.09 |

Direct-column-only controls also improved integer partitions and unpartitioned
windows about 14–15%; computed-key, decimal-fallback and full-sort controls
stayed stable. All measurements were sequential, after build/test activity
stopped, with SQL errors checked on every execution. Evidence:
`_build/direct-window-bench.txt`, `_build/direct-window-controls.txt`,
`_build/window-assembly-bench.txt`, `_build/common-prefix-bench.txt`,
`_build/common-prefix-controls.txt`, `_build/window-final-bench.txt`.
Executor tests: 23/23. Final release results follow.


The exact amd64 release binary passed the full gate: 283 MoonBit tests,
20703 client/corpus passes, three skips, no failures. Arm64 passed 572/572.
Before benchmarking, `ss -tanp` found a TIME-WAIT connection using local
47340; waiting for it to expire avoided the earlier Docker bind failure.
The comparison ran after all builds/tests ended and the ports were clear.
All 48 medians match 240 raw samples. ROW_NUMBER measured 6.01 ms versus
SQL Server 5.60 ms; the previous release measured 7.19 vs 6.07. SQL Server
was broadly faster in this run, so the remaining gap is about 7%, not a win.
Total shape medians are 235 vs 639 ms (about 2.7x), with bitsql's total nearly
unchanged and SQL Server's total lower than in the prior comparison.

The other clear gaps remain GROUP BY v (5.46 vs 5.05 ms) and DISTINCT v
(5.64 vs 4.34). EXISTS is 4.89 vs 4.70; accented ORDER BY is effectively
tied (3.016 vs 3.015). COUNT DISTINCT remains ahead at 3.29 vs 3.66.
The optimization goal remains open. README includes the full current run,
without substituting slower SQL Server values from an earlier run.
Evidence: `harness/out/bench-compare-0.1.17.json`, `_build/bench-0.1.17.txt`,
`_build/check-0.1.17.log`, `_build/arm64-0.1.17.log`.

Published as `0.1.17`, `0.1` and `latest`, with amd64 + arm64 manifests
verified at the same digest:
`sha256:b7df528afb8a658be09b8c689bed84f9e795201d5036f3ee90cdb28983930795`.
Both images carry revision `b16b333068687eb09fa141d2cfa7a61c5f4d33f8`;
revision stamping preserved the tested filesystem layers. The amd64 registry
layers total 12.4916 MiB compressed (README rounds to 12.5).


## Flat grouping and DISTINCT projections (2026-10-06, 0.1.18)

The single-key accumulator aggregate now evaluates one flat value array and
uses `single_value_ids` directly, materializing key rows only for group
representatives. Non-exact types still use the existing comparison fallback
on retained values, without evaluating expressions again. GROUP BY retains
its first spelling and its existing `ansi=false` equality. Aggregate finish
consumes privately allocated key rows instead of copying them; input rows
are never passed to this helper.

A single-expression Project under DISTINCT similarly retains flat values
until grouping finishes. It preserves each projection's `next_row` call,
all expression evaluations before grouping, first-appearance group order and
binary-smallest string representative. Multi-column projections use the old
path. Tests compare outputs, effect traces, NULL warnings, errors and input
immutability with the original materialized paths, including empty input,
NULLs, linguistic/binary collations, mixed kinds and fallback values.

Sequential native measurements, 20k rows, 100 repetitions per query:

| Query | 0.1.17 means (ms) | Flat grouping/DISTINCT means (ms) |
| --- | ---: | ---: |
| GROUP BY p | 1.66 / 1.52 | 1.02 / 1.03 |
| GROUP BY v | 4.93 / 4.77 | 4.20 / 4.18 |
| DISTINCT v | 5.15 / 5.08 | 4.37 / 4.38 |
| COUNT DISTINCT v | 3.29 / 3.24 | 3.30 / 3.20 |
| ROW_NUMBER | 5.94 / 5.86 | 5.92 / 5.94 |
| Unique GROUP BY id | 9.31 / 9.30 | 8.21 / 8.14 |
| Unique DISTINCT id | 8.18 / 7.94 | 7.26 / 7.23 |
| Decimal DISTINCT fallback | 11.08 / 10.93 | 10.41 / 10.46 |
| Multi-column DISTINCT | 19.10 / 18.85 | 18.89 / 19.58 |

The first grouping-only version slightly slowed unique grouping (about 2–4%);
consuming the private output key resolved that and improved unique grouping
about 12%. Computed and NULL grouping keys improved; decimal grouping and
multi-column controls stayed roughly stable. One initial scratch control had
invalid string quoting and was rejected by the benchmark runner; it yielded
no usable comparison and was corrected before the full control run.
Evidence: `_build/flat-group-bench.txt`, `_build/flat-group-controls.txt`,
`_build/flat-distinct-bench.txt`. Release validation and container comparison follow below.


A fixed private array of 64 immutable BIGINT values also reuses small
ROW_NUMBER ranks in both normalized and general paths. Larger ranks retain
normal allocation. The cache neither grows with input nor changes the value
type. Existing window equivalence tests and a boundary test cover it.
Against the flat-grouping/DISTINCT candidate without this cache, 100-repeat
means were 6.34/6.38 → 6.00/5.85 ms for text partitions and 4.45/4.45 →
4.22/4.20 for integer partitions. Unpartitioned windows (3.16/3.23 →
3.21/3.19) and two large partitions (5.93/6.06 → 6.03/6.00) were roughly
stable; decimal fallback improved slightly (16.75/16.50 → 16.44/16.36).
Evidence: `_build/rank-cache-bench.txt`. No benchmarks overlapped builds,
tests or another benchmark.


The exact amd64 release binary passed the full gate: 286 MoonBit tests,
20703 client/corpus passes, three skips, no failures. Arm64 passed 572/572.
The JSON compatibility corpus was also reverified against the SQL Server
oracle (1/1 case passed). All benchmark ports and processes were clear after
the gate; comparison ran sequentially, without build/test activity.

All 48 shape medians agree with the 240 raw samples. Text GROUP BY now wins:
4.67 vs SQL Server 5.17 ms. DISTINCT is 4.82 vs 4.59 (about 5% slower),
EXISTS 4.95 vs 4.86 (about 2% slower), and ROW_NUMBER effectively tied at
5.9209 vs 5.9189. Total shape medians are 232.84 vs 671.80 ms, about 2.9x.
SQL Server's timings changed too, so controlled before/after measurements
above are the evidence for causal gains, not cross-release ratios alone.

The container's 1000 point-SELECT workload measured 154 vs 142 ms, behind
SQL Server and slower than the prior release's recorded wall time. Two
native baseline/candidate request-control pairs, reversing order in the
second pair, did not reproduce a regression: eight runs per binary had
median wall times about 115 ms for both, with similar CPU time. Individual
runs varied on both binaries. README retains the actual new container result
instead of replacing it with a favorable control. This remains a variable
near-parity workload; the broader optimization goal stays open.

Evidence: `harness/out/bench-compare-0.1.18.json`, `_build/bench-0.1.18.txt`,
`_build/check-0.1.18.log`, `_build/arm64-0.1.18.log`,
`_build/json-oracle-0.1.18.log`, `_build/requests-0.1.18-controls.txt`.

Published as `0.1.18`, `0.1` and `latest`; all three amd64 + arm64 manifests
were verified at `sha256:b95402f8549b5d4fedb705d69b37c6c452f3bacc9ce144e49cd8002d2fbd4bb9`.
Both images carry source revision `982cf1bc852fb7239a1ce048596aa39b43ee2a94`;
metadata-only stamping preserved their tested filesystem layers. The amd64
registry layers total 12.4926 MiB compressed.


## Reusing DISTINCT grouping keys for sorting (2026-10-06, 0.1.19)

Single-column DISTINCT already computes canonical collation keys while
hashing. A following sort on that output column, with the same collation
and non-ANSI comparison, can reuse them instead of computing and allocating
another set of keys. The grouping helper returns its existing key array;
ordinary callers discard it. DISTINCT retains representative keys and sorts
with the existing `compare_sort_keys` comparator and stable sort. Integer
grouping does not build canonical keys, so DISTINCT prepares only its final
integer representatives. Binary/ANSI collation differences, mixed types and
other inexact values keep the original materialized sort fallback, without
re-evaluating projection expressions. Different representative spellings
remain canonical-equal; output still uses the existing DISTINCT spelling
rule. The former Sort body is extracted unchanged as `sort_rows`.

Expanded executor equivalence tests compare both directions, matching and
mismatched collations, NULLs, temporal and mixed integer kinds, decimal and
variant fallbacks, expression errors/traces, row evaluation counts and input
immutability against the old DISTINCT-then-sort path.

An initial optional key-collection branch showed a small GROUP BY slowdown
in some runs; moving that collection after grouping did not consistently
resolve it. The final design returns already-built keys and leaves the
hashing loop unchanged. Reversed-order baseline/candidate controls show
unrelated grouping, COUNT DISTINCT, UNION and ROW_NUMBER roughly stable.

Sequential native measurements, 20k input rows, 100 repetitions per query:

| Query | 0.1.18 means (ms) | Candidate means (ms) |
| --- | ---: | ---: |
| GROUP BY p | 1.07 / 1.04 | 1.05 / 1.02 |
| GROUP BY v | 4.21 / 4.41 | 4.29 / 4.28 |
| DISTINCT v | 4.41 / 4.51 | 3.75 / 3.86 |
| COUNT DISTINCT v | 3.22 / 3.24 | 3.25 / 3.24 |
| UNION | 5.96 / 6.07 | 5.96 / 5.93 |
| ROW_NUMBER | 5.68 / 5.73 | 5.61 / 5.70 |
| Unique DISTINCT id | 7.38 / 7.55 | 6.61 / 6.62 |
| DISTINCT v descending | 4.61 / 4.71 | 4.05 / 4.03 |
| Decimal DISTINCT fallback | 10.44 / 10.44 | 10.40 / 10.44 |
| ANSI DISTINCT fallback | 6.65 / 6.59 | 6.57 / 6.57 |
| Binary DISTINCT fallback | 7.97 / 7.99 | 8.00 / 8.00 |
| DISTINCT 80-character prefix | 22.89 / 22.84 | 20.78 / 20.20 |

Long-prefix controls (20 repetitions, outer COUNT to avoid wire-output cost):
1024-character repeated text 172.55/172.05 → 156.30/156.23 ms;
1024-character unique text 303.97/302.41 → 208.62/208.45;
unique short text 6.45/6.31 → 3.94/3.99. Thus key reuse still wins when
comparing long shared prefixes, rather than merely shifting cost to sorting.
All benchmarks ran sequentially after compilation/tests ended; every query
was checked for SQL errors.
Evidence: `_build/distinct-keys-return-bench.txt`,
`_build/distinct-keys-long-controls.txt`; earlier candidates are recorded in
`_build/distinct-keys-bench.txt` and `_build/distinct-keys-final-bench.txt`.
Release gate and container comparison follow below.


The exact amd64 release binary passed the full gate: 286 MoonBit tests,
20703 client/corpus passes, three skips, no failures. ARM64 passed 572/572;
the JSON compatibility case also matched the SQL Server oracle. After all
builds/tests ended, all benchmark ports and processes were clear. The
container comparison ran sequentially; all 48 medians match 240 raw samples.

DISTINCT now beats SQL Server: 4.107 vs 4.723 ms. ROW_NUMBER is 5.893 vs
6.006; EXISTS is essentially tied at 4.954 vs 4.938. Text GROUP BY is 5.053
vs 4.872 (about 4% slower), while the 1000 point-SELECT workload is 140 vs
145 ms. Total shape medians are 234.17 vs 676.50 ms, about 2.9x. README
retains the complete fresh comparison, including the slight GROUP BY loss.

Because GROUP BY shifted relative to 0.1.18 despite stable native controls,
its exact prior release binary was extracted from its image using an owned
stopped container (removed immediately). Sequential 100-repeat comparisons
of those exact release binaries did not reproduce a regression: GROUP BY v
was 4.34/4.36 → 4.20/4.13 ms, DISTINCT 4.57/4.53 → 3.82/3.65, and COUNT
DISTINCT 3.43/3.38 → 3.33/3.30. Other controls stayed roughly stable. The
near-parity container metrics remain variable; a single cross-release table
is not proof of a causal regression or gain. The optimization goal stays open.

Evidence: `harness/out/bench-compare-0.1.19.json`, `_build/bench-0.1.19.txt`,
`_build/check-0.1.19.log`, `_build/arm64-0.1.19.log`,
`_build/json-oracle-0.1.19.log`, `_build/release-distinct-controls.txt`.

Published as `0.1.19`, `0.1` and `latest`; all three amd64 + arm64 manifests
were verified at `sha256:a10828a1480160eeaaef75ba5f9067718478733431f7d9bdf88bd5c508e1c6c9`.
Both images carry source revision `962904b5491c79ebe63c831ce6c2108d6a9f075f`;
metadata-only stamping preserved their tested filesystem layers. The amd64
registry layers total 12.4946 MiB compressed.


## Compiled subquery rows and deferred contexts (2026-10-06, 0.1.20)

Compiled EXISTS and scalar subqueries pass their current row directly into
the existing memo/decorrelation machinery. Previously the fallback interpreter
first copied the full Ctx record with that row, then subquery execution
copied it again to push the row onto its outer stack and clear the current
row. The first copy is redundant: dependency checks use tables/variables,
while correlation and direct execution now receive the explicit row. Scalar
cardinality/value handling is extracted unchanged from the interpreter.
Interpreted calls, IN and quantified comparisons keep a wrapper passing
`ctx.row`, so their semantics remain unchanged.

Correlated lookups also defer constructing the subquery context until after
an empty-match early return. The first partition build still receives its
proper outer context; later empty matches replay the same row-counter/NULL
warning effects and work-budget charge without allocating an unused context.
Tests compare compiled and interpreted execution through cache hits,
missing stamps, table/variable changes, explicit cache clears, NULL warnings,
UDF effects/errors, scalar cardinality errors, nested outer references and
work limits. The supplied row deliberately differs from `ctx.row`.

Sequential native 20k-row controls, 100 repetitions, first change alone:
EXISTS 4.96/5.00 → 4.56/4.48 ms; correlated scalar 3.08/3.11 → 2.68/2.71;
uncorrelated scalar 4.11/4.13 → 3.68/3.68. GROUP BY, DISTINCT, IN, ROW_NUMBER
and DELETE controls remained roughly stable (`_build/subquery-row-bench.txt`).

A second candidate combined deferred empty-match contexts with direct-column
projection/grouping specializations. EXISTS improved further to 3.79/3.85
from 5.00/5.02 (about 23–24%); scalar timings were 2.63/2.65 and 3.63/3.75.
Column-only, computed-projection, computed-group and unique-group controls
did not show a repeatable benefit from the column specializations, so those
specializations and their dedicated test were removed before release. Only
the subquery changes remain. Evidence: `_build/direct-projection-bench.txt`;
final selected-code validation and measurements follow below.

The container comparator now retains five 1000-query point-SELECT samples
and reports their median after one full warm-up batch. Every execution still
checks SQL errors. Earlier versions recorded one batch, which varied enough
to flip the near-parity result; old JSON renders with its original label.
Syntax checking and an old-file render verified backward compatibility.


Final selected-code controls (the projection experiment removed), 100 repeats:
EXISTS 5.04/4.99 → 3.80/3.82 ms, correlated scalar 3.10/3.14 → 2.67/2.69,
uncorrelated scalar 4.10/4.13 → 3.64/3.65. GROUP BY v 4.16/4.36 → 4.34/4.21,
DISTINCT 3.78/3.88 → 3.82/3.82 and ROW_NUMBER 5.64/5.67 → 5.65/5.68 were
roughly stable. Evidence: `_build/subquery-final-bench.txt`.

The exact amd64 release binary passed the full gate: 287 MoonBit tests,
20703 client/corpus passes, three skips, no failures. ARM64 passed 572/572;
the JSON compatibility case also matched the SQL Server oracle. Benchmark
ports and Node/build processes were checked after all tests ended; all
measurements ran sequentially. Node's Linux `comm` is `MainThread` here, so
activity checks now inspect its executable argument too (harness skill).

All 48 shape medians match their 240 raw samples. The two point-read medians
match their ten samples, five per engine. EXISTS now beats SQL Server, 3.66
vs 4.66 ms; scalar subqueries are 2.69 vs 4.59 and 3.68 vs 4.27. Total shapes
are 228.88 vs 644.61 ms (about 2.8x). DISTINCT (4.56 vs 4.26) and ROW_NUMBER
(5.89 vs 5.54) remain about 6–7% behind in this run; GROUP BY v (4.80 vs 4.74)
and accented sorting (3.11 vs 3.03) are near parity. These controls were
stable in the final before/after comparison; SQL Server's timings also
changed. README preserves the complete fresh comparison.

The five-batch point-read medians are 121.75 vs 119.70 ms, about 2% apart.
The raw batches range 109.56–123.27 for bitsql and 114.92–130.02 for SQL
Server. This methodology differs from previous releases' single batch; it
must not be presented as a code-only speedup. The optimization goal remains
open, including the remaining text/window gaps and near-parity workloads.

Evidence: `harness/out/bench-compare-0.1.20.json`, `_build/bench-0.1.20.txt`,
`_build/check-0.1.20.log`, `_build/arm64-0.1.20.log`,
`_build/json-oracle-0.1.20.log`.

Published as `0.1.20`, `0.1` and `latest`; all three amd64 + arm64 manifests
were verified at `sha256:dd7b268e593753e586015324e6607fe8ac0c78848386a86cbb99a2f8d3413283`.
Both images carry source revision `2f8d43274dbdf42c74ff9c350defedc802b063ed`;
metadata-only stamping preserved their tested filesystem layers. The amd64
registry layers total 12.4967 MiB compressed.

### 0.1.21 compact short ASCII keys (2026-10-06)

Grouping and normalized window/sort keys can encode at most eight UTF-16
units of ASCII letters/digits (plus trailing spaces) as one left-aligned
Int64 under the exact default English CI collation. The whole column must
qualify; NULL retains a separate tag. Other collations, ANSI sorting,
punctuation, embedded spaces, NUL, non-ASCII and longer values retain the
existing comparison path. This avoids allocating collation-weight arrays
for the common short-key workload without changing comparison semantics.

`compact_text_wbtest.mbt` compares about 100,000 packed/comparator pairs,
checks grouping against general keys, stable ascending/descending sorts,
multiple keys and mapped columns, and unsupported values at boundary and
interior positions. Oracle capture `traps/compact-text-keys.sql` passes on
both 0.1.20 and the candidate. Separate reduced probes exposed existing
non-ASCII ordering / unsupported-collation differences, documented in
`fidelity-traps.md`; they remain outside the allowlist.

Sequential native controls (20k rows, 100 repetitions, baseline/candidate/
candidate/baseline) show GROUP BY v 4.38/4.29 → 3.53/3.43 ms, DISTINCT
3.88/3.83 → 3.24/3.25, COUNT DISTINCT 3.37/3.25 → 2.55/2.60, and ROW_NUMBER
5.79/5.71 → 4.26/4.20. Integer grouping and text ORDER BY controls remain
roughly stable. Evidence: `_build/compact-text-final-bench.txt`.

The initial implementation added 10–23% to probes with one unsupported
final value and was revised before release: boundary probes reject early,
sort preparation reads original rows directly, and compact grouping
pre-sizes its table. Boundary probes only reject; full validation still
checks every value, so an unsupported interior value cannot silently use
the packed encoding. Interior exceptions can still cost an extra scan.
The final 40-repetition fallback controls retain ANSI, binary-collation and
decimal timings. Unique grouping improves about 9–12%; unique DISTINCT is
7.98/7.97 → 8.21/7.95 ms (one small regression, one tie). Final-value
exceptions are near baseline: COUNT DISTINCT 3.64/3.61 → 3.74/3.62, grouping
2.45/2.45 → 2.50/2.42, ROW_NUMBER 6.89/7.03 → 7.14/7.01. A deliberately
unsupported penultimate value still costs roughly 0.4 ms in COUNT DISTINCT
and 0.3–0.5 ms in ROW_NUMBER. The 1024-character ROW_NUMBER control adds
about 2–3%. These are retained limitations, not universal speedup claims.
Evidence: `_build/compact-text-final-controls.txt`. The container
comparison follows below.

The exact amd64 release binary passed the full gate: 291 MoonBit tests,
20704 client/corpus passes, three expected skips, no failures. ARM64 passed
573/573 in the short QEMU smoke, including the JSON and compact-key cases.
Both cases also matched the live SQL Server oracle (2/2).
Evidence: `_build/check-0.1.21.log`, `_build/arm64-0.1.21.log`,
`_build/oracle-0.1.21.log`.

The fresh container comparison sums to 228.01 vs SQL Server's 643.31 ms
(about 2.8x). Text grouping now wins 4.29 vs 4.68, DISTINCT 3.62 vs 4.36,
COUNT DISTINCT 2.96 vs 3.63, and ROW_NUMBER 4.43 vs 5.51. Accented sorting
is near parity (3.05 vs 3.01). All 48 shape medians were checked against
240 raw samples, and both point-read medians against their five batches.
Builds/tests ended before measurement; the gate's TIME-WAIT connection on
47340 was allowed to expire before the sequential container run.
Evidence: `harness/out/bench-compare-0.1.21.json`, `_build/bench-0.1.21.txt`.

Point reads in that run were 149.37 vs 116.67 ms (bitsql batches
117.98, 144.04, 154.69, 167.06, 149.37). Because this was worse than 0.1.20,
focused sequential baseline/candidate/candidate/baseline controls followed.
Native controls also showed spikes in the old binary. Exact old/new
container binaries, run directly with one warm-up and five 1000-query
batches, gave old medians 106.63/104.38 vs new 104.26/106.46 ms; server CPU
medians were 35.74/33.98 vs 34.91/33.65 ms. These do not reproduce a code
regression, but do not explain the container spike. README retains the
original container result, not a favorable replacement. Point-read
variation and near-parity accented sorting keep the optimization goal
open. Evidence: `_build/compact-point-controls.txt` and
`_build/compact-release-point-controls.txt`.

Publication pending after the source commit; tested filesystem layers will
be checked unchanged when applying the source revision labels.
