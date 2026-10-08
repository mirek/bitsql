# Query Store compatibility

## Release scope (user decision, 2026-10-08)

The user explicitly chose empty views and then questioned whether real Query
Store collection belongs in a CI emulator at all, given performance overhead
and implementation effort. This supersedes the earlier full monitoring release
plan. Completion requires a published amd64+arm64 container with this documented
compatibility layer. The [Microsoft guide](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17)
remains a reference for names, metadata and configuration contracts.

- Fourteen captured catalog descriptors are available. The options view reports
  configuration; the other thirteen views always return no rows, including
  contexts, text, queries, plans, intervals, runtime/wait stats, hints, feedback,
  replicas and internal state. This is an intentional exception to the usual
  unsupported-error policy, not evidence of an idle workload.
- ON/OFF, operation/capture modes and policy values are retained and validated.
  They do not activate collection. CLEAR/CLEAR ALL preserve configuration.
- Native management procedures validate arguments and retain captured SQL Server
  errors, return statuses and completions. Flush/queue clearing succeed for the
  empty store. Operations on query/plan IDs report missing-ID or disabled-store
  errors. No successful plan forcing, hint application or statistics mutation
  is advertised. Other unimplemented capabilities remain explicit errors.
- No per-statement collector, identity map, timer samples or counter updates
  remain in the execution path. Proper collection is deferred unless a concrete
  application-testing need justifies it.

## Evidence and release checklist

Metadata, options and procedure contracts come from native SQL Server
17.0.5005.3 captures in harness/corpus/query-store; detailed findings are in
[the reference](../reference/query-store.md). Workload fixtures are retained as
oracle evidence for possible future work, not claims of supported monitoring.
The query-store-scaffold client test checks all thirteen empty history views
after actual workload and lifecycle changes against captured descriptors.

- [x] Full local gate for 0.1.25: 1,772 MoonBit tests, 23,704 client checks
  (three existing skips), and website tests/build passed.
- [ ] Commit/push main and publish amd64 and arm64 images.
- [ ] Verify registry version/revision and run the published amd64 image's scaffold checks.

## Preserved experimental work

Commit 51b7954 contains the earlier collector/context experiment. Subsequent
uncommitted text/handle work is preserved locally in
harness/out/query-store-live-history.patch. Neither is on this release's query
execution path. The broader oracle captures remain checked in. Revisit real
monitoring only as a separately scoped feature with measured overhead.

The user requires both amd64 and arm64 publication for this release and exempts
local ARM64 runtime tests. The explicit --multiarch publishing option cross-builds
ARM64 from the same generated C and toolchain runtime version without emulation;
local runtime validation covers amd64. Pause this goal after publication and
published-image verification, as requested by the user.
