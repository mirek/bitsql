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
  `session/named_pure_wbtest.mbt`).

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
