# Executor performance

How the executor is made fast without giving up faithfulness, which
techniques from the literature landed, and how to measure. Numbers are for
the 20k-row shapes of `harness/bench/shapes.mjs`.

## Measuring

- `cd harness && npm run bench`: the 24 query/DML shapes against a release
  build (one run each; noisy on a loaded host).
- `npm run bench:compare`: emulator vs real SQL Server containers (README).
- `scripts/profile.sh '<shape regexp>'` or `SQL='...' scripts/profile.sh`: CPU
  profile of the release server without perf or ptrace (an LD_PRELOADed
  SIGPROF sampler); `--callers drop_object` names the bitsql code behind
  runtime frames. Repeated runs print mean and min per query; compare
  binaries by min when other processes load the host.

## Where the time went (2026-10-05)

Profiling the bench put ~45% of executor CPU in memory management: mimalloc
allocation, `moonbit_drop_object` (recursive reference-count release) and
free. Every `Value` constructor with a payload is a heap object, and so is
every tuple, `Option[Int64]` (`Value::as_int64`), row copy and `{ ..ctx }`
record update. Per-row costs were 100–360 ns (`COUNT(*)` over 20k rows:
2.5 ms). Removing per-row allocations is the first lever; algorithms second.

## Techniques that landed

Each entry names the paper the change is drawn from (BibTeX via DBLP).

| Change | Code | Drawn from |
| --- | --- | --- |
| Expressions compiled once per operator run into closures `(Ctx, Row) -> Value`: types, result types and collations resolved once, no per-row `Ctx` copy; unspecialized kinds fall back to `eval` | `exec/compile.mbt` | Feeley & Lapalme, "Using closures for code generation", Computer Languages 12(1), 1987; Tahboub, Essertel & Rompf, "How to Architect a Query Compiler, Revisited", SIGMOD 2018 ([pdf](https://www.cs.purdue.edu/homes/rompf/papers/tahboub-sigmod18.pdf)) |
| GROUP BY / scalar aggregates as one pass over per-group accumulators (COUNT, COUNT_BIG, SUM, AVG of integer/float, MIN, MAX without DISTINCT) instead of collecting each group's rows | `exec/aggregate_fast.mbt` | standard hash aggregation, e.g. Graefe, "Query Evaluation Techniques for Large Databases", ACM Computing Surveys 25(2), 1993 |
| Linguistic collation elements packed into one `Int` each (primary/tertiary/kana/width, or a negative accent weight) and written into two reused buffers; sort keys sized exactly and filled level by level; no tuples or per-character structs; non-ASCII comparison and key building allocate only the key itself. Bit-for-bit checked against the old element-struct code kept in `types/collation_reference_wbtest.mbt` | `types/collation_compare.mbt`, `types/sort_key.mbt` | Unicode Technical Standard #10, "Unicode Collation Algorithm", §7 sort keys ([html](https://www.unicode.org/reports/tr10/)); ICU's 32-bit packed collation elements; Kuiper & Mühleisen, "These Rows Are Made for Sorting and That's Just What We'll Do", ICDE 2023: normalized binary-comparable keys built once per row |

Not paper-derived but measured: integer arithmetic in `Int64` when both
operands are within ±2^31 (was BigInt for every operation), and
`Value::int64_or` instead of the boxed `as_int64` on hot paths.

## Results

| Query (20k rows, min of repeated runs) | before | after |
| --- | ---: | ---: |
| `SELECT COUNT(*) FROM w` | 2.50 ms | 0.83 ms |
| `SELECT SUM(p + 1) FROM w` | 4.16 ms | 1.42 ms |
| `GROUP BY v` (5003 groups, counted) | 8.12 ms | 5.27 ms |
| `MAX(id * 2 + p) … WHERE v <> N'x'` | 5.74 ms | 3.23 ms |
| `ORDER BY N'é' + v, id` (TOP 10; 2026-10-05, packed elements) | 12.64 ms | 8.36 ms |
| `ORDER BY NCHAR(224 + id % 30) + v, id` (TOP 10; same) | 26.23 ms | 21.41 ms |

The accented-text shape's remaining time is outside collation: after the
packed elements, key building and key comparison are ~5% of its samples;
the expression `NCHAR(224 + id % 30) + v` (decimal/int arithmetic, string
calls) and row handling allocate the rest (`scripts/profile.sh 'ORDER BY
accented' --callers _mi_page_malloc_zero`).
