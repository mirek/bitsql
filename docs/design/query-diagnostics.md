# Opt-in query diagnostics

User-approved scope, 2026-10-08. This is a new goal following the published
0.1.25 Query Store scaffold. The user delegated choosing the useful subset;
full SQL Server monitoring replication is explicitly not required.

## Release contract

- On-demand explain/profile for a single result-producing SELECT, through the
  emulator namespace. Ordinary execution collects nothing by default.
- Explain binds without executing and returns a readable logical tree plus
  versioned JSON. Name tables; distinguish logical structure from actual
  execution choices. Bound output size and report truncation explicitly.
- Profile executes the same executor and reports real deterministic counters:
  source/scan access, index lookup attempts/hits/candidates, returned rows and
  existing work units. Record actual join/sort/Top-N choices and their input
  sizes where useful. No inferred SQL Server CPU, page reads or cost estimates.
- Instrumentation must preserve executor optimizations, results and errors.
  Profile state is request-local and cleaned up on failure. Unsupported forms
  fail explicitly; no hidden execution by explain. Avoid adding per-row
  instrumentation checks to the ordinary path.
- Keep all existing Query Store view descriptors available. Unsupported history
  dimensions remain empty, as explicitly approved. Profiling is a bitsql
  diagnostic, not a prediction of SQL Server's production execution plan.
- Add regression tests demonstrating an observable scan/seek or plan-choice
  improvement. Compare enabled and disabled results and quantify disabled-path
  overhead with interleaved native benchmarks before release.
- Document usage and limitations, update the existing website, run the full
  local gate, publish amd64+arm64 from one source revision, and verify the
  registry and a running native container. No local ARM64 emulation.

## Deferred

Historical Query Store aggregation/retention/admission, SQL Server Showplan XML
and optimizer cost emulation, plan forcing, replica/feedback state, per-operator
wall time/CPU and transparent per-statement timing inside arbitrary procedural
batches are deferred. Existing external timing/CPU benchmarks remain useful.
Bounded history may be considered later if actual developer usage justifies it.

## Progress

- [x] Logical explain and versioned report.
- [x] Opt-in actual execution counters and selected physical choices.
- [x] Client API, correctness/error/cleanup tests and regression examples.
- [x] Disabled-overhead and enabled-cost measurements.
- [x] Documentation/site and full gate; both architecture binaries built.
- [x] Multi-architecture publication verification.

## Using the diagnostics

```sql
EXEC emulator.explain @sql=N'SELECT id FROM orders WHERE id=42';
EXEC emulator.profile @sql=N'SELECT TOP 10 id FROM orders ORDER BY total DESC';
```

Both accept exactly one non-null string input, named `@sql` or positional.
Batch EXEC and direct TDS RPC are supported. The string must contain exactly
one result-producing SELECT; CTEs, subqueries and set operations are allowed.
DML, multiple statements, SELECT INTO and variable-assignment SELECTs fail with
an explicit `Emulator:` error. The query uses the calling session's database,
settings and variables. Profile really executes: normal expression effects
(such as consuming a sequence value) still happen.

Explain returns one row with `plan_text` and `report_json` (nvarchar(max)). It
binds and validates without executing the query or reading table rows. Profile
first streams the ordinary query result, then returns that diagnostic row. If
execution fails, partial results and the execution error remain visible, but
there is no success report. Subsequent queries remain uninstrumented.

`report_json.schema_version` is 1; clients should check it before interpreting
fields. `engine` is `bitsql`, `mode` is `explain` or `profile`. `plan` is a bounded
logical tree represented as a preorder node list (`id`, `parent`, `depth`,
`operator`, `detail`), with root parent -1. The limit is 256 nodes, depth 64 and
4096 expression visits; `plan.truncated` marks incomplete output. Node IDs are
local to the report, not stable query/plan identifiers. The tree describes
operators and table names, not full expression text, index names or costs.

Explain sets `returned_rows`, `work_units` and `counters` to null. Profile fills
these fields. Int64 counters are decimal strings to avoid losing precision in
JavaScript. `returned_rows` counts rows emitted by the query, including the
actual serialized output rows of FOR JSON/XML. `work_units` is the delta of
bitsql's existing work-budget counter, not time, CPU, I/O or a universal cost.

| Counter | Meaning |
| --- | --- |
| `source_calls`, `source_rows` | Table-source calls and sum of row-array lengths exposed by those calls, including reuse of cached materializations. Not rows necessarily consumed. |
| `scan_rows` | Successful per-row scan/lock callbacks. Some optimized paths bypass this callback; zero does not prove no table access. |
| `seek_attempts`, `seek_hits`, `seek_candidates` | Storage equality-lookup calls, calls served by an index (including empty hits), and returned candidates before residual filtering. |
| `json_seek_*` | Equivalent counts for JSON-path index candidate lookups. |
| `vector_searches`, `vector_candidates` | Vector-search calls and returned candidates; internal graph exploration is not counted. |
| `scalar_function_calls`, `table_function_calls` | Calls into procedural functions. Their separate execution contexts are not instrumented; `includes_procedural_function_internals` is always false. |

Counters cover the supplied executor context, including subqueries that reuse
it. They are deliberately not per-operator row counts. Cache, decorrelation,
aggregate and window specializations can change which callbacks run. Compare
like-for-like queries and versions; do not add these overlapping counters into
a supposed total of rows or page reads.

`counters.physical_events` contains up to 128 selected observations in execution
order; `physical_events_truncated` indicates overflow. These events are not
mapped to logical node IDs (operators may fuse or execute repeatedly). The
recorded choices are `hash_equi_join`, `sorted_equi_join`, `nested_loop_join`,
`sort_order`, `full_sort`, `top_sort_order`, `top_full_sort` and `top_heap`.
`input_rows` is the input length (left length for joins); `right_rows` is the
right join input or null; `limit_rows` is the resolved Top-N limit or null.
The `sort_order` variants use the executor's specialized ordering path.
Unlisted optimizations are not represented as physical events.

## Default-off and compatibility boundary

Ordinary contexts have no collector. Explicit profiling wraps existing storage
callbacks; ordinary row-processing loops have no added profiling checks.
Join/sort/Top-N operators check once per invocation whether a collector exists.
Reports and counters have request lifetime only: there is no capture policy,
history buffer, timer, background task or retention process.

Query Store configuration is independent: its SQL Server-compatible ON/OFF
metadata does not activate these diagnostics. All history views stay empty,
including after `emulator.profile`. No SQL Server Showplan or Query Store plan
XML is fabricated. This tool diagnoses the emulator and helps test its executor;
production tuning decisions still require SQL Server measurements.

## Validation

`harness/test/query-diagnostics.test.mjs` compares ordinary and profiled result
sets (including metadata), tests scan-to-seek improvements, actual algorithm
choices, direct RPC, explain side effects, error cleanup and the empty Query
Store boundary. Core tests cover suspension and report-size bounds. The
website includes an executable diagnostics example in the same browser engine.

For a native interleaved overhead comparison:

```bash
BASELINE_BIN=/path/to/previous/bitsql BITSQL_BIN=/path/to/new/bitsql \
  node harness/bench/diagnostics.mjs > harness/out/diagnostics-benchmark.json
```

This measures both server CPU and client wall time for complete requests,
including report formatting/transmission when enabled. Measured results are in [executor performance](performance.md#2026-10-08--opt-in-query-diagnostics); release
verification is recorded below.


Release gate: 1,778/1,778 native MoonBit tests; 23,709 client passes, zero failures,
three existing skips; all core packages check on every backend. Website: 12
passes, one existing browser-test skip and production build passed, including
the diagnostics example. The packaged amd64 binary independently passed the
same 23,709 client checks. ARM64 was cross-built, never locally executed.


## Published 0.1.26

Both images are built from `ef97f22759ed0efe9be0b0a75c2e5840a77241c2`.
The version/revision labels were verified after pulling both registry images.
Tags `0.1.26`, `0.1` and `latest` resolve to the same amd64+arm64 index:

- Index: `sha256:e809242a7f4c6ae8f9cb9c3117b0d5daf1e4ddd381a98d86224f714d094b2a89`
- amd64: `sha256:e2882d76296ec4c0ef8c8d969c4d24440f6a17fc96830e4f5a33da24b215c4dc`
- arm64: `sha256:22b0cd84ce001cbcca1f1a73a1f5d81a885a2477c19b94d2bfed64784fde0112`

A container started from the pulled amd64 image passed all five diagnostics
client tests, the captured empty Query Store descriptor/workload check and the
release-version check (7/7). Diagnostics tests use isolated databases and clean
them up, so they also work with `BITSQL_ADDR` targeting a shared server.
ARM64 was not executed locally. The verification container was removed.

The [website deployment](https://github.com/mirek/bitsql/actions/runs/37754882471)
succeeded; the [live site](https://mirekrusin.com/bitsql/) advertises 0.1.26,
explains the default-off boundary and includes an executable diagnostics example.
