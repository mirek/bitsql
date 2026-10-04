# DONE-token (completion) model

How SQL Server reports statement completions. Distilled from msduck
`docs/control-completions.md` and `docs/nocount.md` (SQL Server 2025 captures),
plus the bitsql corpus (`harness/corpus/msduck/*completion*`, `nocount-*`,
`try-completion-tokens*`). The session interpreter must reproduce this exactly;
the harness compares `tokens` (name, curCmd, status bits, count) and `stream`.

## CurCmd per statement (decimal)

| Statement | CurCmd | Count? |
| --- | ---: | --- |
| SELECT (result set), `SET @v = expr`, `SELECT @v = ...`, `DECLARE @v t = expr` | 193 (0xC1) | yes (1 for assignment) |
| INSERT | 195 | yes |
| DELETE | 196 | yes |
| UPDATE (WITH … UPDATE also 197) | 197 | yes |
| MERGE | 279 | yes |
| MERGE failing with 8672 (repeated match) | 253, or 279 once an OUTPUT result set started (earlier actions' rows are sent); batch ends, rollback ENVCHANGE after the ERROR | no |
| CREATE TABLE | 198 | no |
| DROP TABLE | 199 | no |
| CREATE INDEX | 200 | no |
| DROP INDEX … ON t | 201 | no |
| CREATE/ALTER VIEW | 207 | no |
| DROP VIEW | 208 | no |
| CREATE/ALTER (OR ALTER) PROCEDURE, CREATE/ALTER FUNCTION | 222 | no |
| DROP PROCEDURE | 223 | no |
| DROP FUNCTION | 179 | no |
| CREATE/ALTER TRIGGER | 221 | no |
| DROP TRIGGER | 225 | no |
| DROP SCHEMA (missing: error 15151) | 170 | no |
| `ENABLE`/`DISABLE TRIGGER x ON t` statement | none of its own; a batch with no other completion ends with DONE 253 (gaps-triggers #057-#065) | no |
| TRUNCATE TABLE | 234 | no |
| CREATE DATABASE | 203 | no |
| DROP DATABASE | 204 | no |
| CREATE/DROP SCHEMA | no DONE of its own (batch or RPC); a batch with no other completion ends with DONE 253 | no |
| BREAK / CONTINUE | 202 | no |
| ROLLBACK | 210 | no |
| BEGIN TRAN | 212 | no |
| ALTER TABLE (every action) | 216 | no |
| RETURN (bare) | 219 | no |
| RETURN <expr> (in a procedure) | 193 | yes, 1 |
| SET flag option ON / OFF (NOCOUNT, XACT_ABORT, ANSI_*, ARITHABORT, IMPLICIT_TRANSACTIONS, NOEXEC, FMTONLY, …) | 185 / 186 | no |
| SET QUOTED_IDENTIFIER | none (no DONE of its own) | |
| SET STATISTICS IO/TIME | 188 | no |
| SET ROWCOUNT n | 189 | no |
| SET TEXTSIZE n | 190 | no |
| SET TRANSACTION ISOLATION LEVEL, DATEFIRST, DATEFORMAT, LANGUAGE (+ ENVCHANGE language, INFO 5703), LOCK_TIMEOUT, DEADLOCK_PRIORITY, CONTEXT_INFO | 249 | no |
| SET IDENTITY_INSERT t ON / OFF | 183 / 184 | no |
| WAITFOR DELAY/TIME | 243 | no |
| RAISERROR / THROW (caught) | 246 | no |
| PRINT | 247 | no |
| IF / WHILE condition evaluation | 192 (0xC0) | no |
| failed statement / batch-level error | 253 (0xFD) | no, DONE_ERROR |
| enter TRY | 349 | no |
| enter CATCH | 350 | no |
| normal exit of a CATCH handler | 351 | no |
| DONEPROC at end of RPC | 224 (0xE0) | no |
| DECLARE CURSOR, `SET @c = CURSOR …`, FETCH INTO | 193 | no |
| `SET @c = cursor_name` / `= @other` | 193 | yes, 1 |
| FETCH without INTO | 193 (result set, see Cursors) | yes, 0 or 1 |
| positioned UPDATE / DELETE (WHERE CURRENT OF) | 125 / 126 | yes |
| DBCC USEROPTIONS | 230 with the row count, then INFO 2528 and a second DONE 230 without count (not under WITH NO_INFOMSGS) | yes |
| WAITFOR with an argument of another type (9815) | 243 with the error bit; the batch continues | no |
| OPEN cursor | 32 | no |
| CLOSE cursor | 43 | no |
| DEALLOCATE cursor | 44 | no |
| EXEC proc / dynamic SQL in a batch | DONEPROC 224, statements inside DONEINPROC | no |

`DECLARE` without an initializer and `BEGIN … END` grouping emit nothing.
DDL errors complete with 253 (batch ends) outside TRY; see
`docs/design/fidelity-traps.md` (DDL errors). Captures: `harness/corpus/catalog/`.
Codes not listed here (COMMIT, MERGE, …) must be
taken from captures before they are implemented. Add them here when found.

## Rules

- **IF/WHILE:** every successful condition evaluation emits an uncounted DONE
  with cmd 192, including false conditions and the final WHILE test.
- **TRY/CATCH:**
  - Entering TRY emits 349 before the body.
  - A caught error first completes the failed statement: RAISERROR/THROW emit
    246 without the error flag; a failed query emits 193 with 0 rows and its
    metadata stays visible. Then entering CATCH emits 350.
  - Normal CATCH exit emits 351, even for an empty CATCH. An entirely empty TRY
    is a syntax error.
  - RETURN (219), BREAK and CONTINUE (202) abandon the pending handler exits
    they cross. A rethrow into an outer handler emits a THROW completion and the
    outer CATCH entry, with no end token for the abandoned inner handler.
- **Batch vs RPC:** batch statements end with DONE and RPC statements with
  DONEINPROC; every one carries MORE except the last DONE of a batch. An RPC
  ends with RETURNVALUEs, RETURNSTATUS, then DONEPROC (cmd 224).
- **NOCOUNT ON:**
  - In SQL batches, top-level statement completions (DONE) remain but
    DONE_COUNT is cleared and the count is 0. Inside procedures and triggers
    the ordinary DONEINPROCs are suppressed, as in RPCs (triggers/after-update-columns).
  - In RPCs, ordinary statement completions (assignments, PRINT, DML without
    OUTPUT, control flow) are suppressed. Result sets (even with 0 rows), DML
    OUTPUT results and error completions are kept, and the final DONEPROC and
    RETURNSTATUS always remain.
- **Errors:** a statement-terminating error emits ERROR then a DONE with
  DONE_ERROR, cmd 253 for compile-time and batch errors. When the failed
  statement's result schema was already known (runtime error in a query),
  COLMETADATA is sent first and the DONE carries cmd 193 with the error flag
  (mssqlite-todo/runtime-error-stream-fidelity.md).
- **Reuse probe:** the harness runs `SELECT @@TRANCOUNT AS trancount,
  XACT_STATE() AS xact_state` and `SELECT 1 AS reusable` after every case.
  `@@TRANCOUNT` is fixed `Int` with flags 32; `XACT_STATE()` is `IntN(2)` with
  flags 33.

DDL resets `@@ROWCOUNT` to 0 (msduck `docs/ddl-completion-reference.md`).

## Triggers (corpus `triggers/`)

Trigger statements complete with DONEINPROC before the firing statement's own
DONE, whose count is the statement's rows; @@ROWCOUNT and SCOPE_IDENTITY() are
restored after the trigger, @@IDENTITY is not. A trigger that ends the
transaction (ROLLBACK) finishes, then the batch ends with 3609 (line of the
firing statement) and DONE 253 + error; rolling back the implicit autocommit
transaction sends no ENVCHANGE.

## Statement-terminating errors followed by 3621

Every run-time error of an INSERT/UPDATE/DELETE/MERGE that does not end the
batch (constraint violations, 8134, 8115, 220, 232, 248, 512, 550, ...) and
lock timeouts (1222) are followed by INFO 3621 "The statement has been
terminated." (class 0) before the statement's DONE with the error bit, outside
TRY (captured: catalog/filtered-unique, locking/lock-timeout,
output/dml-error-completion, output/stream-errors). This includes WHERE
errors of UPDATE/DELETE, which complete with the DML CurCmd, not 253.
Batch-ending errors (245, any error under XACT_ABORT ON) get no 3621, and the
DML statement completes with DONE 253, unless an OUTPUT result set was
already started (then the DML CurCmd). 547 raised by ALTER TABLE ... CHECK
is not followed by 3621.

## Nested EXEC

`EXEC proc` at the top level of a batch or RPC ends with RETURNSTATUS and
DONEPROC 224. Inside a procedure, trigger or sp_executesql text it ends with
DONEINPROC 224 only, without RETURNSTATUS (captured: proc/nested-exec-tokens,
applock/rpc-prisma). System procedures written in T-SQL (sp_getapplock,
sp_releaseapplock) also emit the DONEINPROC tokens of their own statements:
see `session/applock.mbt` for the captured sequences.

## Procedures, EXEC strings and sp_executesql (2026-10-04)

Captured: `harness/corpus/proc/*` (return-status, abort-tokens,
exec-errors, exec-args, nest-levels, xact-abort-lines), msduck-gaps
`gaps-procedures`, `gaps-rpc-procedures`, msduck-runs `savepoint`.
Implemented in `session/rpc.mbt` (`run_module`, `exec_module_end`) and
`session/interp.mbt` (`exec_one`).

- **Module end.** `EXEC proc` and `EXEC (string)` at the top of a batch end
  with RETURNSTATUS + DONEPROC 224; nested ones with DONEINPROC 224 only,
  which NOCOUNT suppresses. `EXEC (string)` returns a status like a
  procedure.
- **Return status.** RETURN's value; otherwise 10 minus the highest
  severity (> 10) of the errors the module's own statements raised, caught
  or not (11 → -1, 14 → -4, 16 → -6, 18 → -8); errors of nested modules and
  of the EXEC statements themselves (2812, 266, argument errors) do not
  count. A bare RETURN after an error also gives -6. RETURN NULL sends INFO
  282 ("The 'p' procedure attempted to return a status of NULL ...", line
  of the RETURN) before its DONEINPROC and returns 0. sp_executesql returns
  the last @@ERROR instead (also 266 and the number of an error that ended
  its text).
- **@@ERROR after EXEC** is the module's last @@ERROR (50000 after
  `EXEC('RAISERROR(...)')`, 0 after a procedure whose last statement
  succeeded).
- **Errors that end only the module** (compile-time: 208, syntax errors and
  137/178 in dynamic SQL): no completion for the failed statement, the
  module completes with DONEPROC/DONEINPROC 224 with the error bit and no
  RETURNSTATUS, `EXEC @r =` leaves @r unchanged, @@ERROR is the error and
  the caller continues. sp_executesql still sends RETURNSTATUS (the error
  number), over RPC followed by the OUTPUT parameters' *input* values.
- **Errors that end the batch inside a module** (245/241/8114 conversions,
  THROW, any error under XACT_ABORT, 217): no completion for the failed
  statement and no DONEPROC/DONEINPROC of the modules it leaves; the batch
  ends with one DONE (error bit) whose CurCmd is the failed statement's if
  it had sent COLMETADATA (193), else 253; an RPC ends with DONEPROC 224
  with the error bit, without RETURNSTATUS or RETURNVALUEs. Any batch-ending
  error completes with 253 unless a result set had started (also IF
  conditions, PRINT, COMMIT under XACT_ABORT). The rollback ENVCHANGE of
  XACT_ABORT or a batch-ending conversion error follows the ERROR.
- **Errors of the EXEC itself** (2812 state 62, argument errors 201/8145/
  8143/8162, argument conversion 8114 state 5): ERROR, then DONEPROC 224
  (nested: DONEINPROC) with the error bit; the batch continues. Argument
  errors report line 0. 8144 (too many arguments) and 119/179 are compile
  errors: DONE 253, batch ends. A value that does not fit an OUTPUT
  variable is 8114 state 2 at line 0 and ends the batch.
- **266** (line 0): procedure and EXEC string: RETURNSTATUS, ERROR,
  DONEPROC with the error bit; sp_executesql: ERROR, RETURNSTATUS 266,
  DONEPROC. Also for `EXEC sp_executesql N'BEGIN TRAN'` sent as RPC.
- **TRY in a caller** catching an error inside a module: every module it
  leaves completes with DONEPROC/DONEINPROC 224 *without* the error bit
  (32 of them for the 217 of a 33rd level), then CATCH (350). Errors of the
  EXEC itself under TRY: DONEPROC 224 (no error bit), then CATCH.
- **Procedure RPC**: arguments are named or positional by wire position
  (positional after named is allowed); validation errors (2812, 201, 8144,
  8145, 8143, 8162, 8114 state 1) send ERROR + DONEPROC with the error bit.
  RETURNVALUEs carry the type the client declared (bigint, nvarchar(n) with
  truncation), named as sent ("" for positional ones), after RETURNSTATUS.
- **sp_prepexec / sp_prepare**: RETURNSTATUS precedes the handle's
  RETURNVALUE; a batch-aborting error discards the handle (its number is
  reused). sp_prepare of a non-query sends DONEINPROC 193 with count 0.

## Cursors (2026-10-04, msduck-runs `cursor`, corpus `stmts/cursor-*`)

Implemented in `session/cursor.mbt` (its header lists the type conversions
and data models).

- **FETCH result:** COLMETADATA of the cursor's columns plus a trailing
  `ROWSTAT int` (flags 0; 1 fetched, 2 deleted keyset row), then TABNAME
  (only when a result column is a base column: none for COUNT(*) or
  constants), COLINFO, ORDER when the query has ORDER BY, the ROW (none past
  either end) and DONE 193 with count 1 or 0. FETCH INTO sends only DONE 193
  without count.
- **Errors keep the batch going** and complete with the statement's CurCmd
  and the error bit: OPEN 32 (16905, 16916, 16950), FETCH 193 (16911 with
  the lower-case fetch type, 16917 state 2, 16924, 16925 "Absolute"),
  CLOSE 43 (16917 state 1), DEALLOCATE 44, DECLARE 193 (16915). Rejected
  FETCHes set @@FETCH_STATUS -1 and do not move the cursor.
- **Lines:** 16916/16950 from OPEN and FETCH report the line of the previous
  statement that set the current line (0 at the start of a batch or module;
  DECLARE without initializer does not set it; after a failed statement the
  next one reports its own line). CLOSE and DEALLOCATE report their own line.
- **Compile errors:** conflicting options 1048 (fixed wording per pair, e.g.
  "FOR UPDATE and STATIC", "STATIC and FAST_FORWARD") and mixed ISO/T-SQL
  syntax 1049 (line 0) reject the whole batch with DONE 253.
- **Positioned DML** errors (16929 READ ONLY, 16931 no current row, 16932
  column outside FOR UPDATE OF, 16933 another table, 16947 row gone) are
  followed by INFO 3621 and DONE 125/126 with the error bit.
- TYPE_WARNING conversions send INFO 16956 (class 0) at the DECLARE's line
  before its DONE.

