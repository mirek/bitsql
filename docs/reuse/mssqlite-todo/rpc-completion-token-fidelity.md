# RPC completion-token fidelity

## Evidence

The `alter table alter column` live case executes two statements through
tedious `sp_executesql`: ALTER COLUMN followed by SELECT. SQL Server emits an
uncounted statement completion for ALTER, a counted `DONEINPROC` for SELECT,
then a final uncounted `DONEPROC`. mssqlite instead reports a row count of 1 on
the ALTER completion and ends with `DONEPROC`, omitting the separate SELECT and
final RPC completions.

The differential corpus declares five exact differences under
`/execution/done`; the new per-case communication trace preserves the packet
and decoded token sequence used to diagnose them.

The trace also shows the broader rule: SQL Server emits one intermediate
completion for each DROP/CREATE/INSERT statement used by case setup and cleanup,
while mssqlite can collapse the group to the counted DML completion or omit the
DDL completion entirely. This affects cases whose main result snapshots agree.

## Work

Separate engine work performed by a DDL rebuild from the statement's public
row count. Render one completion per top-level statement and an independent
final RPC completion, with `MORE`, `DONE_COUNT`, and token family matching SQL
Server. Audit ordinary SQL batch and stored-procedure paths so the correction
does not manufacture RPC-only tokens elsewhere.

Likely boundaries are engine result-item production and
`packages/server/src/respond.ts` RPC wrapping.

## Acceptance

- The five exact DONE differences for this case become stale and are removed.
- Focused wire tests cover two-statement RPC, SQL batch, DDL plus SELECT,
  NOCOUNT ON/OFF, and a procedure body.
- The communication trace has the same application-response token ordering as
  SQL Server after ignoring documented server-specific token fields.
- `pnpm test` and `pnpm test:differential` pass.
