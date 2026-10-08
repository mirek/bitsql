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
errors and compile-time validation completions are covered. The context-settings view now exposes captured contexts. Other history views
raise an explicit unsupported error while their implementation is pending.

The descriptor generator now consumes every captured step, checks descriptor
counts, and supports datetimeoffset metadata. The 14 history/option descriptors
are generated without inferring types from runtime values.

Next: per-database history, execution instrumentation and host measurements,
management procedures and live history rows. Extend captures for missing
contracts as each part is implemented. The configuration chunk passed `scripts/check.sh`: 1,772 MoonBit tests,
23,694 passing client checks (three existing skips), and the website checks/build; no new release has been published for this work yet.

Procedure validation progress: `procedures-on`, `procedures-off`,
`procedure-arguments`, `procedure-rpc`, and `procedure-errors` now match the
oracle. This covers absent-ID/disabled-state errors, type/arity checks, status
variables, error scope and wire completions. Positive operations on stored
queries/plans still require the history implementation. The combined procedure/collector chunk passed the full gate: 1,779 MoonBit
tests, 23,703 client checks (three existing skips), and website tests/build.
All nine Query Store allowlisted cases executed and passed; selectors must
include their `.sql` suffix. The preceding configuration chunk is `48baf01`.

Execution collection progress: successful statements in ALL mode retain database,
text, procedure object, context, actual row counts and supplied event timestamps.
READ_ONLY/OFF preserve history; CLEAR removes it. Collection survives transaction
rollback and avoids double counting suspended-request replay. Seven focused tests
cover those paths. `context-view` matches the oracle. AUTO/CUSTOM admission,
failed executions, query/plan projections and resource measurements remain
unfinished; no timing or resource metrics are synthesized from row counts.

Five more oracle cases (`query-identity`, `query-text`, `context-settings`,
`context-view`, `execution-errors`) reproduce with populated results. They establish identity
relationships, context flags and execution classifications for the next chunk.
