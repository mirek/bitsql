# Execution model

Inside the core, the executor is a pure step function. A lock wait parks the
session in core state instead of blocking, and the engine resumes it when the
lock is released.

```moonbit
enum Step {
  Row(Row, ExecState)
  Info(SqlMessage, ExecState)          // PRINT, RAISERROR severity < 11
  NeedLock(LockRequest, ExecState)     // scheduler grants now or parks the session
  Done(Int64, ExecState)               // rowcount
  Fail(SqlError, ExecState)
}

fn step(state : ExecState, db : DbSnapshot) -> Step
```

Operators are Volcano-style pull iterators. Vectorization is not worth it for
CI-sized data. Long statements yield (`Output::Yield`) after a work budget so one
session cannot starve the others, and ATTENTION is honored between steps.

## One DML delta, many consumers

Every DML statement produces one delta. Triggers, `OUTPUT`, FK checks, index
maintenance and `rowversion` all consume it.

```moonbit
struct Delta {
  table : TableId
  inserted : Array[Row]   // the `inserted` pseudo-table
  deleted : Array[Row]    // the `deleted` pseudo-table
}
```

Consumers run in SQL Server's order:

1. INSTEAD OF triggers, which replace the DML entirely when present
2. Constraint checks: PK, unique, CHECK, FK (error 547)
3. `OUTPUT` (without `INTO`, it is disallowed when the target has enabled triggers)
4. AFTER triggers, in the same transaction

`ROLLBACK` inside a trigger ends the batch with error 3609. Nested triggers are
allowed and recursion is off by default.

## Scope stack

The session holds a stack of scopes: batch, proc, dynamic SQL and trigger.

| Item | Visibility |
| --- | --- |
| Variables | Own scope only. `sp_executesql` sees only passed parameters. |
| Temp tables (`#t`) | Creating scope and inner scopes; dropped when the creating scope ends |
| Table variables | Own scope only |
| `SCOPE_IDENTITY()` | Per scope |
| `@@IDENTITY` | Session-wide, so triggers that insert make it diverge from `SCOPE_IDENTITY()` |
| `@@ROWCOUNT`, `@@FETCH_STATUS`, `@@ERROR` | Reset by almost every statement |
| Cursors | `LOCAL` per scope (default for v1); `GLOBAL` per session |

Dynamic SQL is parse and bind at run time inside a new scope. Parse and bind are
pure and cheap, so plan caching is optional.

## Error model as data

TRY/CATCH fidelity depends on classifying each error. The classification lives
in `Semantics.classify_error`, not scattered through the executor.

| Class | Effect | Example |
| --- | --- | --- |
| Informational | INFO token, execution continues | `RAISERROR` severity ≤ 10, `PRINT` |
| Statement-terminating | Statement rolled back, batch continues | Constraint violation 2627 without `XACT_ABORT` |
| Batch-aborting | Batch ends, transaction stays open | Conversion errors, `THROW` without `XACT_ABORT` |
| Transaction-dooming | `XACT_STATE()` = −1, only rollback allowed | Any error under `XACT_ABORT ON` inside TRY |

CATCH blocks expose `ERROR_NUMBER()`, `ERROR_MESSAGE()`, `ERROR_SEVERITY()`,
`ERROR_STATE()`, `ERROR_LINE()` and `ERROR_PROCEDURE()`. A bare `THROW`
re-raises the original error. Deadlock victims get 1205 and a rolled-back
transaction.

Error text, severity and state must match SQL Server byte for byte; the
canonical messages come from captured references (see `fidelity-traps.md`).
