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
