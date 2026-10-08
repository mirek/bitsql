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
- No Query Store per-statement collector, identity map, timer samples or
  counter updates remain in the ordinary execution path. Proper collection is deferred unless a concrete
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
- [x] Commit/push main and publish amd64 and arm64 images (source ae74375).
- [x] Verified registry version/revision for both architectures and ran the
  published amd64 image: version/scaffold tests 2/2 and targeted oracle
  differentials 4/4 passed.

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

For opt-in inspection of the emulator itself, see [query diagnostics](query-diagnostics.md).
Those request-local reports do not populate any Query Store view.

## Published 0.1.25

The full packaged-amd64 client suite passed 23,704 checks with zero failures
and three existing skips. ARM64 was cross-built and its ELF architecture and
published version/revision were verified; it was not runtime-tested locally.
The version, 0.1 and latest tags all resolve to the same manifest list:

- Index: sha256:03d845e2cdf84097c711cce8d2ea7b76b9623a5de5ecc0253dff8fc4a90925d4
- amd64: sha256:00b53c2a300b93970e466cc40f38abbcf98c03945268873f31ccb87288da584c
- arm64: sha256:d7aa9dc67adacedced2c315e08fa80c0583691942fc4c33652efab115b2a76e0

Both images identify source revision ae74375e8927515a4a3f85be080d397996d4ed69.
The user requested pausing this goal after the scaffold release; full monitoring
collection is not scheduled as automatic follow-up work.
