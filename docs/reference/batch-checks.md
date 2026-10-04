# Batch-level compile errors and related statement rules

Rules derived from captures (SQL Server 17.0.5005.3) in long-tail round 4,
2026-10-04. "Whole batch" means ERROR + DONE 253: no statement of the batch
runs, not even ones before the failing statement. Implemented in
`src/core/session/precheck.mbt` and `precheck_hints.mbt` unless noted.

## Table hints in FROM (corpus `tail/table-hints`, `tail/table-hints-gaps`, msduck-runs tedious-compat-gaps #080-#098)

Checked in two passes over the batch. First pass (class 15):

- Unknown hint: 321 `"Bogus" is not a recognized table hints option.`,
  spelled as written. FASTFIRSTROW is unknown.
- Conflicting locking hints: 1047 `Conflicting locking hints specified.`
  when two different isolation classes meet (NOLOCK = READUNCOMMITTED,
  READCOMMITTED, READCOMMITTEDLOCK, REPEATABLEREAD, SERIALIZABLE =
  HOLDLOCK), two different granularities (ROWLOCK, PAGLOCK, TABLOCK,
  TABLOCKX), UPDLOCK with XLOCK, or NOLOCK with any granularity or lock
  mode. TABLOCK/TABLOCKX with UPDLOCK, NOWAIT with anything, READPAST with
  READCOMMITTED/REPEATABLEREAD/UPDLOCK/TABLOCK are fine.
- FORCESEEK with FORCESCAN: 10746.

Second pass (class 16, per table):

- SNAPSHOT on a disk table: 367 `The hint 'SNAPSHOT' is valid only with
  memory optimized tables.`
- NOEXPAND on a table or a non-indexed view: 8171 state 2 `Hint 'noexpand'
  on object 'hp' is invalid.` (hint lower-case, object as written);
  IGNORE_CONSTRAINTS / IGNORE_TRIGGERS in a SELECT: 8171 state 1.
- INDEX(name) missing: 308 `Index 'IX' on table 'hp' (specified in the FROM
  clause) does not exist.`; INDEX(n) missing: 307 `Index ID n …`.
- INDEX(0) with another index (`INDEX(0), INDEX(1)`, `INDEX(1, 0)`): 8622
  state 2; FORCESEEK with INDEX(0): 8622 state 1.
- FORCESEEK without any predicate on the leading key column of an index
  (no WHERE, or `WHERE v = 1` on a non-key column), and FORCESEEK on a view:
  8622 state 1 "Query processor could not produce a query plan …".
- READPAST with NOLOCK or SERIALIZABLE is 650 *after* COLMETADATA (DONE 193
  with the error bit); bitsql raises 50100.
- INDEX hints on a view: INFO 4430 `Warning: Index hints supplied for view
  'hv' will be ignored.` before the result; bitsql raises 50100.

Legacy form without WITH: `FROM t (NOLOCK)` and `FROM t a (NOLOCK)` accept
one hint; several (`t (NOLOCK, READPAST)`) or an unknown word are 207 per
word + 215 "Parameters supplied for object 't' which is not a function…"
(not emulated); `t (INDEX(0))` is the syntax error 1018. Table variables
take no hints: `FROM @t WITH (…)` is 319 (the WITH starts a new statement),
`INSERT/UPDATE @t WITH (…)` 156 near 'WITH' (+ 319, which bitsql does not
report). 319's keyword always prints as `'with'`.

## TOP (corpus `tail/top-invalid`, `top-invalid-abort`, `top-fractional`, msduck-runs select-top-percent, merge-top)

| Count | Constant (whole batch, class 15) | Variable (run time, class 15, ends the batch) |
| --- | --- | --- |
| negative row count | 127 `A TOP N or FETCH rowcount value may not be negative.` | 127 |
| NULL row count | 1060 `The number of rows provided for a TOP or FETCH clauses row count parameter must be an integer.` | 1014 `A TOP or FETCH clause contains an invalid value.` |
| non-integer type (1.5, 2.0, float, '2', a decimal variable) | 1060 | 1060 at compile time too |
| PERCENT outside 0..100 | 1031 `Percent values must be between 0 and 100.` | 1031 |
| PERCENT NULL | 1014 | 1014 |

Run-time ones come after COLMETADATA, end the batch without a rollback, and
in an RPC the DONEPROC follows the ERROR directly. A DML TOP adds INFO 3621
after 127 but not after 1014. The same applies to UPDATE/DELETE/MERGE TOP
constants. Run-time NTILE ≤ 0 or NULL (4116) behaves like the run-time TOP
errors in an RPC (msduck-runs ntile-null #013/#015).

## Window functions (corpus `tail/window-arity`, `tail/window-missing-over`)

- Wrong argument count with OVER: 4114 `The function 'ROW_NUMBER' takes
  exactly 0 argument(s).` (ROW_NUMBER, RANK, DENSE_RANK, PERCENT_RANK,
  CUME_DIST: 0; NTILE: 1); LAG/LEAD: 10755 `The function 'LAG' takes between
  1 and 3 arguments.` Class 15, name as written.
- Without OVER: 10753 `The function 'X' must have an OVER clause.`, state 3
  for ROW_NUMBER/RANK/DENSE_RANK/NTILE/CUME_DIST/PERCENT_RANK, state 1 for
  LAG/LEAD/FIRST_VALUE/LAST_VALUE.

## MERGE WHEN clauses (corpus `tail/merge-when-clauses`, msduck-runs merge-execution #043/#044)

Within one WHEN kind (`WHEN MATCHED`, `WHEN NOT MATCHED`, `WHEN NOT MATCHED
BY SOURCE`): a repeated action is 10714 (class 15) `An action of type 'WHEN
MATCHED' cannot appear more than once in a 'UPDATE' clause of a MERGE
statement.`, checked first; a clause after one without a search condition
is 5324 (class 16). Both fail the whole batch.

## Other whole-batch checks

- An undeclared table variable in FROM: 1087 state 2 (class 15), also at
  CREATE PROCEDURE (msduck-runs table-variable #014/#038). A table variable
  is visible only in its own batch/module: EXEC(), sp_executesql and
  procedures get 1087 (#023/#024).
- A named constraint inside `DECLARE @t TABLE (…)` is 156 near 'CONSTRAINT'
  (#010); 2705 for a duplicate column names the variable as written,
  state 3.
- Niladic functions with parentheses (`CURRENT_TIMESTAMP()`, `USER()`,
  `SESSION_USER()`, `SYSTEM_USER()`, `CURRENT_USER()`): 102 near the token
  after `(` (`tail/niladic-parentheses`).
- Unknown BACKUP option: 155 `'BOGUS' is not a recognized BACKUP option.`,
  state 1 for a bare word, 2 for `word = value` (`tail/backup-errors`).

## Statement rules found on the way

- BACKUP DATABASE/LOG of a database that does not exist: 911 (state 11,
  LOG 10) then 3013 `BACKUP DATABASE is terminating abnormally.`, DONE 228
  (LOG 235) with the error bit; the batch continues, @@ERROR is 3013; TRY
  catches 3013 without printing 911. RESTORE of a missing file is 3201 +
  3013 (not emulated: 50100).
- END CATCH (CurCmd 351) sets @@ROWCOUNT to 0 whether or not the CATCH
  block ran (`tail/try-catch-rowcount`).
- COUNT(NULL) in an UPDATE SET is 8117 before 157 (msduck-runs
  count-null-compilation#064).
- A computed column declared `PERSISTED NOT NULL` is NOT NULL in
  sys.columns but keeps its expression's nullability in result metadata
  (tedious-compat-gaps #038/#039); an index on a non-deterministic computed
  column is 2729.
- UPDATE/DELETE … FROM with an outer join skip rows where the target is
  NULL-extended; APPLY in their FROM sees the target row
  (msduck gaps-outer_dml).
- EXEC sp_prepare in T-SQL: a single SELECT compiles at prepare time and
  sends COLMETADATA (+ ORDER) and DONEINPROC 193 count 0; a compile error is
  the error + 8180 `Statement(s) could not be prepared.`, status 8180, no
  handle; several statements, a syntax error or a procedure call prepare
  without compiling (status 8182, a handle, no message); @options = 0 is 214
  state 3; sp_execute status is the last @@ERROR; unknown handles 8179 state
  4 (sp_execute) / 8 (sp_unprepare) (`tail/prepare-in-batch`).
- Columns read through a view or inline function report as base columns
  (flags 0x08) unless computed: `MIN(v)` via a view is flags 9, via a
  derived table 1 (`tail/views-column-flags`).
