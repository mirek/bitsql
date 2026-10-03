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
| UPDATE (also MERGE?; WITH … UPDATE seen as 197) | 197 | yes |
| CREATE TABLE | 198 | no |
| DROP TABLE | 199 | no |
| CREATE INDEX | 200 | no |
| DROP INDEX … ON t | 201 | no |
| CREATE/ALTER VIEW | 207 | no |
| DROP VIEW | 208 | no |
| TRUNCATE TABLE | 234 | no |
| CREATE/DROP SCHEMA | 253 (RPC: no DONEINPROC at all) | no |
| BREAK / CONTINUE | 202 | no |
| ROLLBACK | 210 | no |
| BEGIN TRAN | 212 | no |
| ALTER TABLE (ADD/DROP COLUMN) | 216 | no |
| RETURN (bare) | 219 | no |
| RETURN <expr> (in a procedure) | 193 | yes, 1 |
| SET option (NOCOUNT on/off: 185/186) | 185/186 | no |
| RAISERROR / THROW (caught) | 246 | no |
| PRINT | 247 | no |
| IF / WHILE condition evaluation | 192 (0xC0) | no |
| failed statement / batch-level error | 253 (0xFD) | no, DONE_ERROR |
| enter TRY | 349 | no |
| enter CATCH | 350 | no |
| normal exit of a CATCH handler | 351 | no |
| DONEPROC at end of RPC | 224 (0xE0) | no |
| DECLARE CURSOR, FETCH (INTO) | 193 | no |
| OPEN cursor | 32 | no |
| CLOSE cursor | 43 | no |
| DEALLOCATE cursor | 44 | no |
| EXEC proc / dynamic SQL in a batch | DONEPROC 224, statements inside DONEINPROC | no |

`DECLARE` without an initializer and `BEGIN … END` grouping emit nothing.
Codes not listed here (COMMIT, CREATE PROC/FUNCTION/TRIGGER, MERGE, …) must be
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
  - In SQL batches, statement completions remain but DONE_COUNT is cleared and
    the count is 0.
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
