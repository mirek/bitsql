# READPAST, table hint shapes, ALTER SCHEMA TRANSFER, sticky LOB space, sp_prepare of non-SELECT statements

Rules distilled from captures on SQL Server 17.0.5005.3 (2026-10-04):
`harness/corpus/tail5/b2-readpast.sql`, `b2-readpast-snapshot.sql`,
`b2-hints.sql`, `b2-schema-transfer.sql`, `b2-lob-space.sql`,
`b2-prepare.sql`, plus `tail/table-hints-gaps.sql`,
`tail/prepare-in-batch-dml.sql`, msduck-runs `all-objects#029`,
`object-catalog-width#030/#047/#054/#061`.

## READPAST (650, 4102)

- 650 "You can only specify the READPAST lock in the READ COMMITTED or
  REPEATABLE READ isolation levels." (class 16) is a **run-time** error: it
  fires when the table is read, so a SELECT sends its COLMETADATA first
  (DONE 193 with the error bit), an assignment SELECT or DML completes with
  DONE 253, earlier statements of the batch have run, `WHERE 1=0` reads
  nothing and raises nothing, a subquery or join input counts.
- It ends the batch (the next statement does not run), rolls back an open
  transaction (ERROR, then ENVCHANGE rollback), and TRY catches it (a caught
  UPDATE sends its DONE 197 before CATCH).
- The isolation is the table's locking hint, else the session level.
  Fails: NOLOCK/READUNCOMMITTED, SERIALIZABLE/HOLDLOCK, SNAPSHOT session
  (UPDLOCK or HOLDLOCK do not help under SNAPSHOT). Passes: READCOMMITTED,
  READCOMMITTEDLOCK, REPEATABLEREAD hints (also overriding a SERIALIZABLE or
  SNAPSHOT session), READ COMMITTED with READ_COMMITTED_SNAPSHOT ON, UPDLOCK,
  XLOCK, TABLOCK. A SELECT fails even for a primary-key point lookup.
- UPDATE/DELETE/MERGE targets (their own hints or their FROM occurrence's):
  a READ UNCOMMITTED session does not count (writes lock anyway). Under
  SERIALIZABLE (hint or session) or SNAPSHOT they fail, except an
  UPDATE/DELETE whose WHERE is exactly `pk = constant or variable` for the
  clustered primary key (`id = 1`, `id = @i`, `h.id = 1` pass; `id IN
  (7, 8)`, `id = 1 AND v = 3`, a UNIQUE constraint column, no WHERE fail).
  MERGE fails with an ON clause on the key.
- READPAST on an INSERT target is 4102 (class 15) for the whole batch:
  "The READPAST lock hint is only allowed on target tables of UPDATE and
  DELETE and on tables specified in an explicit FROM clause."

Code: `bind/readpast.mbt` (the scan runs behind `%READPAST`, evaluated by
`session/readpast.mbt` when it opens), `session/readpast.mbt`
(`readpast_target` for DML targets), `session/precheck.mbt` (4102).

## Table hint shapes

- INDEX hints on a view: INFO 4430 "Warning: Index hints supplied for view
  'hv' will be ignored." (class 0) at compile time, before anything in the
  batch runs, once per view reference (two references: two INFOs, also in a
  subquery or TRY), index names and ids are not checked. FORCESEEK on a view
  without predicates stays 8622.
- INDEX hints on an INSERT/UPDATE/DELETE target (also a view): 1069 (class
  15) "Index hints are only allowed in a FROM or OPTION clause." for the
  whole batch; on the target's FROM occurrence they are fine.
- `FROM t (a, b)` on a table or view (not a function), unless it is one
  legacy hint word (also bracketed: `t ([NOLOCK])` works): one 207 "Invalid
  column name 'w'." per bare word, then 215 "Parameters supplied for object
  't' which is not a function. If the parameters are intended as a table
  hint, a WITH keyword is required.", whole batch. The 215 of a
  schema-qualified name (`dbo.hp (v)`) reports line 13 and names it as
  written. A missing object is 208 (bitsql: 50100), an undeclared variable
  argument 137 (bitsql: 50100).
- `FROM t alias (NOLOCK, X)` or `(NOLOCK X)`: 1018 near X when X is a hint
  word, else 102 near X; `t alias (word)` with an unknown word is 321.

## ALTER SCHEMA … TRANSFER

`ALTER SCHEMA s TRANSFER [OBJECT:: | TYPE:: | XML SCHEMA COLLECTION::] name`
(unqualified names resolve in dbo):

- Success sends no DONE of its own (the batch-final DONE 253 if alone). The
  object keeps its object_id; a table takes its constraints (PK, DEFAULT,
  CHECK) along; modules keep their text, so a view naming `dbo.t1` fails
  when used after the table moved (208 + 4413, both at line 13). Into the
  object's own schema: nothing happens. Rolled back with the transaction.
- Errors (statement-level, DONE with CurCmd 170; a caught one sends no DONE
  before CATCH): 15151 "Cannot find the object 'x', because it does not
  exist or you do not have permission." (also for a constraint name; "the
  type", "the xml schema collection"), 15151 "Cannot alter the schema 'x',
  …" for a missing target schema, 15530 'The object with name "t1" already
  exists.', 33144 "Cannot change the schema of a temporary object.", 2710
  for sys.
- Code: `session/schema_transfer.mbt`. Not captured (bitsql 50100):
  schema-bound dependents, a trigger or constraint name taken in the target
  schema, a type name taken.

## lob_data_space_id

sys.tables.lob_data_space_id is 1 once the table has had a LOB column
(varchar/nvarchar/varbinary(max), xml, text, ntext, image), and stays 1
after the column is dropped or narrowed, after sp_rename, TRUNCATE and (probe; bitsql does not parse REBUILD)
`ALTER TABLE … REBUILD`; a rolled-back ADD leaves 0. Code:
`store.Table::lob_used`, kept sticky by `Db::create_table/alter_table/
replace_table`.

## EXEC sp_prepare of one non-SELECT statement (T-SQL)

The statement compiles at prepare time and sends DONEINPROC with its own
CurCmd, then RETURNSTATUS 0 and DONEPROC:

| Statement | DONEINPROC |
| --- | --- |
| INSERT / DELETE / UPDATE / MERGE | 195 / 196 / 197 / 279, count 0 |
| `SET @p = …`, `SELECT @p = … FROM …` | 193, count 0 |
| SET NOCOUNT ON | 185, no count |
| CREATE TABLE | 198, no count |
| BEGIN TRAN | 212, no count |
| PRINT | 247, no count |

A DML OUTPUT clause sends its COLMETADATA before the DONEINPROC. Compile
errors (208, 207) are the error + 8180 and no handle. DECLARE and IF prepare
deferred (RETURNSTATUS 8182, no DONEINPROC). Code: `session/prepare_exec.mbt`
(`prepare_compile`: DML runs with `Session::compile_only` until its OUTPUT
header). Unverified: other SET options (185 ON / 186 OFF assumed), other
statement kinds (50100).
