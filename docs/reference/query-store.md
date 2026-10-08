# Query Store capture findings

Captured on SQL Server 17.0.5005.3 (2026-10-08), in fresh isolated user databases.
Authoritative fixtures: `harness/corpus/query-store/*.expected.json`.

- `view-descriptors`: 14 SQL Server 2025 catalog views, including options,
  contexts, texts, queries, plans, runtime stats/intervals, waits, internal state,
  hints, feedback, variants, replicas and plan-forcing locations. Metadata comes
  from `SELECT * ... WHERE 1 = 0`, not inferred from populated values.
- `options`: new databases default to READ_WRITE/AUTO, 900-second flush,
  60-minute intervals, 1000 MB storage, 30-day retention and 200 plans/query.
  OFF and READ_ONLY preserve configured values. CLEAR ALL preserves options.
- `options-validation`: interval 7 is error 153/state 6/class 16; flush 0 is
  153/state 5/class 15. Storage 0 and max plans 0 are accepted. CUSTOM exposes
  its configured capture thresholds. ALTER DATABASE inside a transaction is
  226/state 6, while invalid option names/modes fail compilation with 102.
- `procedures-on/off`: flush and queue clearing succeed in either mode;
  consistency checking succeeds only while OFF (12427/state 3 while ON).
  Force/unforce and hints reject OFF with 12405; remove-plan/query still validate
  missing IDs (12403/12402). Reset statistics while OFF succeeds even for a
  missing plan. Missing `@feature_id` for remove-plan-feedback is 214/state 56.
- Query Store errors identify the database with an allocated numeric ID. The
  harness normalizes only that field in known Query Store error objects;
  query/plan IDs, user result cells and unrelated errors remain unmodified.
  `sp_query_store_reset_exec_stats` on a nonexistent plan while ON prints
  unstable integers for both IDs on this oracle build. Only that message is
  masked; number, state, severity and completion stream remain checked.
- Workload captures poll for observed ingestion (bounded to ten seconds) before
  inspecting history or changing capture modes. Fixed waits alone produced empty
  histories or incomplete counts on this oracle. Runtime rows are aggregated
  across memory and persisted parts of an interval. Setup DML can
  itself be captured, so SELECT-history tests explicitly exclude it. Do not
  accept an empty joined result as evidence of successful capture.
- `procedure-workload`: two procedure calls returning 2 and 1 rows produce two
  executions, average rowcount 1.5, min 1, max 2. The stored query text includes
  the `(@min int)` parameter declaration and retains procedure object identity.

- `options-lifecycle`: configuring while OFF retains OFF; ON restores the prior
  READ_ONLY/READ_WRITE choice. CUSTOM without explicit thresholds uses
  30 executions, 1000 ms compile CPU, 100 ms execution CPU and 24 hours.
  Switching to AUTO hides these policy fields (NULL). Master's options view is
  empty; enabling master/tempdb emits 12438 followed by 5069. Flush 86401 is
  accepted; max plans 2147483648 fails parsing with 102 near the number.

- `procedure-arguments`, `procedure-rpc`, `procedure-errors`: these native
  procedures consume arguments by position even when labels are supplied
  (`@plan_id=91, @query_id=92` to force-plan searches query 91). Too few
  arguments produce 313/state 51; too many produce 8144/state 51 (feedback
  uses state 120), without RETURNSTATUS. Invalid argument types produce
  214/state 51 plus status 1 and an error DONEPROC. Numeric text and decimal
  arguments are not implicitly converted to bigint.
- Query Store execution errors report line 1, including when EXEC is on a later
  batch line or is called directly by RPC. Inside TRY, ERROR_PROCEDURE() is
  `sys.sp_query_store_remove_query`, the return variable retains its old value,
  and the native procedure completes before control enters CATCH. Outside TRY,
  the return variable becomes 1 and @@ERROR retains the Query Store error.
- `procedure-arguments`: remove-plan-feedback takes feature_id first. Omitting
  it gives 201/state 62 and return status 201; feature_id 1 gives 12468 and
  return status 12468. Force/unforce validate the optional disable-optimized-
  forcing flag before looking up IDs (12460 for 3). More feature/replica and
  valid-plan paths remain to be captured with execution history.

- `query-identity`: unparameterized query text has a 44-byte statement handle,
  an 8-byte query hash, object_id 0, parameterization type 0 (`None`) and one
  linked plan for the captured workload. Handle contents are opaque identities.
- `context-settings` and `context-view`: NOCOUNT does not split query identity;
  DATEFIRST, DATEFORMAT, ARITHABORT, ANSI_WARNINGS and QUOTED_IDENTIFIER do.
  The default set_options bytes are `000010fb`; disabling the latter three
  removes bits `0x1000`, `0x10` and `0x40`, respectively. Context status is
  `0400`, default_schema_id is -2, and ordinary SELECT cursor/merge fields are 0.
- Initial executions immediately after enabling Query Store sometimes were not
  ingested even with a fixed delay. New identity/context/error fixtures warm up
  until the target query appears before measuring. The exception fixture resets
  stats after warmup, then captures one `Exception` (execution_type 4) and one
  `Regular` (0). Exception rowcount varied despite no client rows, so that
  unstable value is not asserted; the regular execution returns two rows.

- `statement-handle`: `sys.fn_stmt_sql_handle_from_sql_stmt` returns the captured
  text's existing 44-byte handle for parameterization 0 or NULL. Uncaptured text,
  a different parameterization (1), and parameterization 4 each return no rows
  in this capture. The returned type column is `query_parameterization_type`.
  This is a lookup contract, not evidence that arbitrary text can be hashed to
  a SQL Server handle. The [function reference](https://learn.microsoft.com/en-us/sql/relational-databases/system-functions/sys-fn-stmt-sql-handle-from-sql-stmt-transact-sql?view=sql-server-ver17)
  documents a 64-byte metadata maximum, while this oracle exposes 44 bytes.
