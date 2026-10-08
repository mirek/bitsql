# Query Store performance monitoring

Active work requested 2026-10-08. Completion requires a newly published native
container with working monitoring support, not just catalog names or empty views.
The reference is [Microsoft's Query Store monitoring guide](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17).

## Implementation and release requirements

- Parse and apply Query Store ON/OFF, operation/capture modes, interval/flush/
  retention/storage/plan limits, cleanup/wait settings and custom capture policy.
  Support CLEAR and CLEAR ALL. Validate syntax and values against oracle errors.
- Database-scoped query, text, context, plan, runtime interval and wait history;
  record actual executions, including parameterized SQL and stored procedures.
  Preserve history across OFF/READ_ONLY and implement the capture policy.
- Bind the captured catalog metadata for the 14 views in
  `harness/corpus/query-store/view-descriptors.sql`; supply meaningful live rows.
  Include `sys.databases.is_query_store_on` and correct cross-database isolation.
- Implement flush, statistics reset, plan/query removal, force/unforce, message
  queue clearing and consistency checks, including SQL batch and RPC invocation.
  Audit Query Store hints, feedback, replicas and the statement-handle function
  listed by the reference. Unsupported engine capabilities must raise explicit
  emulator errors; never advertise successful plan forcing without its effect.
- Measure runtime metrics at the host boundary and pass observations to the pure
  core. Do not fabricate SQL Server CPU, reads, memory or Showplan information.
  Define and document faithful emulator metrics and explicit unsupported areas.
- Verify lifecycle, isolation, capture modes, statistics aggregation, stored
  procedure attribution, execution failures and cleanup using oracle-derived
  corpus and meaningful host/client tests. Add passing cases to the allowlist.
- Run `scripts/check.sh`, update knowledge and version, push to main, publish
  using `scripts/docker-publish.sh --push`, and verify registry manifests and
  a running instance of the published native image. Benchmark as required by
  knowledge-upkeep. Do not combine different versions in multiarch manifests.

## Current evidence and next work

The nine `harness/corpus/query-store/` cases establish wire metadata,
configuration/defaults/validation, enabled/disabled procedure errors, SELECT
and stored-procedure execution statistics, plan forcing/removal/reset, and
history retention across capture-mode transitions. Expectations are captured
from the native SQL Server 17.0.5005.3 oracle. See
[Query Store capture findings](../reference/query-store.md).

The parser now preserves Query Store actions and policy settings. Database options
retain configuration across OFF/ON; `sys.database_query_store_options` and
`sys.databases.is_query_store_on` reflect it. All three option cases match the
oracle and all 83 captured batches agree on parsing. System-database enable
errors and compile-time validation completions are covered. History views still
raise an explicit unsupported error while their implementation is pending.

The descriptor generator now consumes every captured step, checks descriptor
counts, and supports datetimeoffset metadata. The 14 history/option descriptors
are generated without inferring types from runtime values.

Next: per-database history, execution instrumentation and host measurements,
management procedures and live history rows. Extend captures for missing
contracts as each part is implemented. The configuration chunk passed `scripts/check.sh`: 1,772 MoonBit tests,
23,694 passing client checks (three existing skips), and the website checks/build; no new release has been published for this work yet.
