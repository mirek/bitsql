# Query Store and diagnostic history

## Current scope (0.1.27)

The October 8 compatibility report supersedes the intentionally empty 0.1.25
scaffold for the workload it reproduces. The native host now collects successful
outer SELECT/DML executions and supplies clock/CPU measurements to the pure core
through replayable events. `QUERY_CAPTURE_MODE=ALL` populates query text, query,
context, plan identity, runtime statistics and interval relationships. History
is memory-only, like the databases themselves.

- Repeated statements aggregate execution counts, returned/affected rows,
  duration and CPU. Runtime buckets follow the configured interval length.
  Identical text under different captured SET contexts has distinct identities.
- Durations are elapsed microseconds across the statement execution boundary;
  CPU is measured per engine turn, excluding other sessions while a request
  waits. Binding and statement dispatch are included. These are measurements
  of bitsql, not predictions of SQL Server performance.
- READ_ONLY and OFF retain history without capturing; NONE continues existing
  entries and excludes new ones. CLEAR/CLEAR ALL remove stored history while
  preserving options. Flush makes the already synchronous, in-memory collection
  visible; it does not imply durable storage.
- Reset statistics, remove plan and remove query operate on captured IDs. Plan
  removal preserves the query and a later execution receives a new plan ID.
  Unsupported forcing/hint operations on real IDs return an explicit Emulator
  error. Invalid IDs and argument errors retain the captured SQL Server errors.
- SQL Server catalog descriptors remain oracle-derived. Plan identities link
  actual observations; `query_plan` is NULL, not fabricated SQL Server Showplan.
  Query/plan handles are emulator identities and are not SQL Server's private
  binary handle encoding.

### Boundaries

This is scoped execution history, not complete SQL Server Query Store. Nested
procedural statements are not independently timed; native top-level batches
and directly executed sp_executesql/prepared query bodies are the measurement
boundary; stored-procedure bodies are not captured independently. AUTO and
CUSTOM policy values retain their earlier metadata-only behavior; automatic
admission, retention/quota enforcement, compilation metrics, plan forcing,
Showplan XML, wait categories and replicas remain unimplemented. Existing
empty descriptors for those unsupported history dimensions are retained from
the previously approved scaffold. Embedded/browser engines do not have a host
measurement driver and do not collect query history.

Nullable metrics that are not measured remain NULL. Mandatory resource fields
for SQL Server subsystems absent from this memory-only executor remain zero.
Do not interpret them as measured SQL Server page I/O, memory grants or waits.

## Diagnostic views

- `sys.dm_exec_query_stats` contains actual execution counts, row counts and
  host-sampled elapsed/CPU time. Its bounded instance history evicts at 4096
  distinct statement/context entries. `sys.dm_exec_sql_text(handle)` supports
  correlated APPLY for diagnostic joins. These are observations of the emulator;
  it does not retain SQL Server physical execution plans.
- `sys.dm_db_index_usage_stats` records storage seeks, scans and index writes,
  with timestamps. Counts are deduplicated per statement/index/access kind and
  survive transaction rollback. Dropped databases remove their history.
- The three missing-index views expose linked advice after successful simple
  selective equality scans. Included columns come from the projection. Costs
  use candidate rows; impact estimates the fraction of candidate rows avoided,
  using observed selectivity. These are advisory emulator estimates, not SQL
  Server optimizer cost units. Advice is limited to 600 entries and is hidden
  when a covering index exists or the table's column layout changes. Joins,
  aggregates, complex predicates and hypothetical plan costing are outside
  this advisor's scope.
- `sys.dm_db_partition_stats` shares the existing `sys.partitions`/
  `sys.allocation_units` model: exact live row counts; modeled page allocations,
  verified for small tables, not a SQL Server storage engine.
- `sys.dm_os_sys_info` reports native host CPU/memory/topology, container type,
  system uptime and the instance-start timestamp. SQL executor scheduling is
  single-threaded. SQL Server-only scheduler/memory-manager fields are not
  implemented. Field meanings follow the
  [Microsoft catalog reference](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-os-sys-info-transact-sql).

## Evidence

`harness/corpus/report-0125` is captured from native SQL Server 2022
16.0.4236.2. It covers the original workload, temporal NULL controls and adjacent
types, filtered-index versus CHECK serialization, descriptor contracts,
partition/index diagnostics, query-cache text joins, Query Store mode changes
and maintenance, and populated missing-index joins with covering-index cleanup.
The report's old image was independently identified as
`sha256:b528e440146d4d765a0543839ff230975b6c8d754aa51a5344702c6dbe729bc3`,
revision `ae74375e8927515a4a3f85be080d397996d4ed69`.

Pure-core tests drive deterministic host samples across runtime intervals,
verify transaction-independent usage history and stale-advice safety. Client
tests run all seven original TOP(1) reads and compare their column descriptors
to the oracle. Existing opt-in [explain/profile](query-diagnostics.md) remains
available for more detailed request-local executor counters.

Release gate for the 0.1.27 changes: 1,780 MoonBit tests and 23,723 client/corpus
checks passed, zero failures, three existing client skips. All core packages
check on every backend. Website tests/build passed (12 tests and one existing
browser skip). Packaged-binary and publication verification are recorded below
when complete.
