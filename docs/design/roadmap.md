# Roadmap and live status

Each phase ends at a gate the harness can check; the first value arrives at
gate 3 when migrations run green. **Keep the checkboxes current**: tick an item
in the same commit that makes it true, and add newly discovered work as
unchecked items. The ranked failure list from the differential harness
overrides the order inside a phase.

Legend: `[x]` done and tested, `[~]` partially done (say what is missing), `[ ]` not started.

## Phase 0: project setup

- [x] MoonBit module, vendored docs with rerunnable update script
- [x] Design split into topic docs, project skills
- [x] Reuse inventory of msduck / mssqlite (`docs/reuse/`)
- [ ] CI workflow — deferred on purpose (too much churn); local `scripts/check.sh` is the gate

## Phase 1: capture and harness

- [x] `harness/` package: tedious 20.3.3 + mssql 12.7.2, connect helper (emulator via BITSQL_BIN/BITSQL_ADDR, oracle container `bitsql-oracle` on 47314); `npm test` skips cleanly until the emulator runs SQL
- [x] Corpus format (`.sql` with `-- @step`/`-- @param`, `.cases.json`) + `capture` (real MSSQL → `.expected.json`); smoke (18) and traps (17) captured on 17.0.5005.3
- [x] `diff` runner: run corpus against emulator, compare, ranked failure list (`harness/out/report.json`)
- [~] Import msduck `reference/*.json` captures that fit the corpus format: 1153 cases from the 76 clean-layout files ≤ 1 MB, each verified on the local oracle. Missing: the ~123 files in other layouts, the 24 prepared-protocol entries (needs a `prepared` step kind), and samples of the 31 files > 1 MB
- [ ] **Blocked on access:** capture one CI run of the target app with tedious
      debug logging; grep its SQL for `OBJECT_ID|COL_LENGTH|sys\.|INFORMATION_SCHEMA|UPDLOCK|HOLDLOCK|SERIALIZABLE`.
      Needs the app repo path or a capture from its owner.
- Gate: corpus checked in; harness runs it against real MSSQL.

## Phase 2: TDS and the core boundary

- [x] Packet framing (reassembly across reads, split by negotiated size, EOM)
- [x] PRELOGIN request decode / response encode (`ENCRYPT_NOT_SUP`)
- [x] LOGIN7 decode; LOGINACK, ENVCHANGE (database, packet size, collation), INFO, DONE
- [x] SQLBatch decode (ALL_HEADERS, UTF-16LE text)
- [~] Token encoders: COLMETADATA, ROW, ORDER, DONE/DONEPROC/DONEINPROC, ERROR, INFO, RETURNSTATUS, RETURNVALUE done; NBCROW missing (only needed if captures show SQL Server using it for our shapes)
- [x] RPC decode: proc id / name, params with TYPE_INFO and values (incl. PLP); dispatch of sp_executesql/sp_prepexec is in session work
- [~] ATTENTION: acknowledged as a separate DONE_ATTN message; real cancellation needs time-sliced execution
- [x] Engine::handle + native host (TcpServer, queue, `--listen`, `listening on` contract), `--record` event log and `replay` tool, timers (SetTimer/CancelTimer → TimerFired, used by LOCK_TIMEOUT)
- [x] Transaction manager requests (0x0E: TM_BEGIN/COMMIT/ROLLBACK/SAVE as tedious beginTransaction and mssql `Transaction` send them; corpus `tm/`, harness `-- @step tm`). Distributed TM requests raise 50100
- [x] Bulk load: `INSERT BULK` + BulkLoad (0x07) messages (tedious newBulkLoad, mssql `request.bulk`): options CHECK_CONSTRAINTS, KEEP_IDENTITY, KEEP_NULLS, FIRE_TRIGGERS ignored (triggers never fire); responses captured (DONE 253, then DONE 240 + count; errors + 3621). Tests: harness `test/mssql-workflow.test.mjs`
- [x] tedious 20.3.3 connects (encrypt:false), login SET batch accepted; other SQL → `Emulator:` error via stub executor
- [x] Stub executor replaced by parser + binder + executor (core/bind, core/exec, core/session)
- **Gate met 2026-10-03**: `tedious` runs `SELECT 1` and a parameterized `sp_executesql`, identical to MSSQL in the harness (smoke/select-1, smoke/rpc-*).

## Phase 3: parser coverage, DDL and catalog

- [x] Lexer (bracket/quoted identifiers, N'' strings, comments incl. nested `/* */`, `GO` separators):
  `core/lex` (`lex`, `split_go_batches`), spans with line/col on every token.
- [~] Expression parser, SELECT, DML, DDL, procedural statements: `core/parse` covers the
  v1 list (expressions with T-SQL precedence, SELECT/CTE/set ops/APPLY/OPENJSON/FOR JSON,
  INSERT/UPDATE/DELETE/MERGE/OUTPUT, CREATE/ALTER/DROP TABLE/INDEX/VIEW/PROC/FUNCTION/
  TRIGGER/SCHEMA/TYPE/SEQUENCE, GRANT/DENY/REVOKE, DECLARE/SET/IF/WHILE/TRY/THROW/
  RAISERROR/EXEC/cursors/transactions, tedious's login SET batch). Missing: PIVOT/UNPIVOT,
  WITH XMLNAMESPACES, GROUP BY ALL / WITH ROLLUP, TABLESAMPLE, FOR SYSTEM_TIME, legacy
  `FROM t (NOLOCK)` hints, `.WRITE`, xml/CLR method calls (`x.value(...)` parses as a
  qualified call), `type::Method()`, DDL triggers (`ON DATABASE`), CREATE/ALTER DATABASE,
  ALTER INDEX, ENABLE/DISABLE TRIGGER statements, `EXECUTE AS` statement, `EXEC ... AT`,
  legacy `RAISERROR n 'msg'`, `SET @cursor = CURSOR ...`, JSON_OBJECT.
  Error numbers 102/156/111/319/10713 follow captures where available; trailing statements
  after CREATE VIEW/FUNCTION and the THROW-after-unterminated rule are unverified guesses.
- [~] Parse differential over the corpus: 1707/1707 batches agree with SQL Server (`npm run parse-diff`); `parsecheck FILE...` ready for the target codebase (needs app repo)
- [~] Types: int family, bit, decimal, (n)varchar, datetime2, datetimeoffset, uniqueidentifier, rowversion
      (`src/core/types`: values, precedence/result types, CAST/CONVERT, checked arithmetic,
      comparison and collations, emulator error table. Missing: `harness/corpus/traps` cases
      for the new type traps and oracle captures for the unverified choices listed in the
      t-sql skill findings (no MSSQL was run for this work), non-ISO date strings / DATEFORMAT / LANGUAGE, CONVERT styles beyond
      0/1/2/3-12/20-25/100-112/120/121/126/127, float style 3, decimal ↔ binary,
      money styles beyond 0/1/2, collations other than Latin1_General/SQL_Latin1.
      Done 2026-10-03: CP1252 best fit (captured table), collation precedence
      468/4191/451 incl. derived tables and set operations, string-expression
      metadata (corpus `collation/`). Open: multiple 451 errors per statement,
      451 for ORDER BY / GROUP BY keys, sql_variant / SQL_VARIANT_PROPERTY)
- [x] Store: `PMap` + `core/store` Db (tables, rows by rowid, unique/non-unique index maps incl. `IS NOT NULL` filtered indexes, modules, schemas, constraint object ids, stable column_id / index_id)
- [~] DDL execution: CREATE/DROP TABLE (columns, NULL/NOT NULL, IDENTITY, DEFAULT, computed, PK/UNIQUE/CHECK/FK incl. self-reference), temp tables, table variables, TRUNCATE; ALTER TABLE ADD (columns incl. DEFAULT/WITH VALUES/identity/computed, constraints WITH CHECK/NOCHECK), DROP COLUMN/CONSTRAINT [IF EXISTS], ALTER COLUMN, CHECK/NOCHECK CONSTRAINT, ENABLE/DISABLE TRIGGER; CREATE/DROP INDEX (unique → 1505 on build, filtered); CREATE/DROP SCHEMA; CREATE/ALTER/DROP VIEW/PROCEDURE/FUNCTION/TRIGGER registered as store Modules (sys.sql_modules, OBJECT_ID); sp_rename (tables, columns); errors 2714/1750, 1779, 4902, 4924, 3728/3727, 5074/4922, 3725, 4917/4916, 4920, 4901, 1088, 1911, 1913, 3723, 3701, 15151, 2759, 3729 captured (corpus `catalog/`). SELECT from views binds the stored query like a derived table (Catalog.view hook). Missing: DML through views (reports 208), filtered UNIQUE indexes other than `IS NOT NULL`, ALTER TABLE ADD INDEX, sp_rename of indexes, user-defined types, `sysname` user_type_id 256 in sys.columns
- [~] Virtual `sys.*` / `INFORMATION_SCHEMA` views (scope 2, rows computed from the Db; descriptors generated from captures by `scripts/gen-sysviews.py`): sys.objects (+118 seeded system objects), tables, views, procedures, columns, types, schemas, indexes, index_columns, key_constraints, foreign_keys, foreign_key_columns, check_constraints, default_constraints, computed_columns, sql_modules, triggers, databases, time_zone_info; INFORMATION_SCHEMA TABLES/COLUMNS/ROUTINES/VIEWS/TABLE_CONSTRAINTS/KEY_COLUMN_USAGE/REFERENTIAL_CONSTRAINTS. Catalog functions OBJECT_ID (types, `tempdb..#t`), OBJECT_NAME, OBJECT_SCHEMA_NAME, SCHEMA_ID/NAME, COL_LENGTH, COL_NAME, COLUMNPROPERTY, OBJECTPROPERTY, INDEXPROPERTY, TYPE_ID/NAME, DB_ID, DB_NAME(id), IDENT_CURRENT/SEED/INCR, OBJECT_DEFINITION, HAS_PERMS_BY_NAME. Missing: sys.identity_columns (sql_variant; raises 50100), sys.all_objects/all_columns/system_objects, system-table rows in sys.columns/indexes, other catalog views (50100), `db.sys.x` for other databases, OBJECTPROPERTYEX
- [~] User-defined functions (2026-10-03, `harness/corpus/udf/*`, `session/udf.mbt`, `bind/udf.mbt`): scalar UDFs in any expression (SELECT/WHERE/ORDER BY, SET/DECLARE, UPDATE, computed columns, defaults, CHECK), argument conversion, DEFAULT arguments, RETURNS NULL ON NULL INPUT, recursion with 217 at level 33, errors at the caller's line; inline TVFs (parameters, CROSS/OUTER APPLY); multi-statement TVFs (return table, 3621 after an error); `EXEC [@r =] dbo.scalar_fn`; CREATE FUNCTION checks 443/444/455/178/1075/2772; binding errors 195/4121/313/8144/206/208/216/317. Missing: compile-time errors (313/8144/4121) do not abort the statements *before* them in the batch (SQL Server compiles the whole batch first), DROP FUNCTION referenced by a computed column (3729), INFO 2007 for EXEC of a missing procedure in a body, cursors and EXEC inside function bodies (50100), sys.columns/sys.parameters rows for functions, SCHEMABINDING checks
- Gate: all migration scripts run green.

## Phase 4: DML and access paths

- [~] Binder + IR (core/bind, core/ir) with captured metadata rules; Semantics record not extracted yet (T-SQL rules inline)
- [~] Executor: scan, filter, project, nested-loop joins (inner/left/right/full/cross), sort, limit, distinct, union all, values, streaming result sets (rows before a run-time error stay sent)
- [x] Query language (2026-10-03, `harness/corpus/query/*`): aggregates (COUNT/COUNT_BIG/SUM/AVG/MIN/MAX/STRING_AGG WITHIN GROUP/STDEV/VAR, DISTINCT), GROUP BY expressions, HAVING, ROLLUP/CUBE/GROUPING SETS + GROUPING/GROUPING_ID, INFO 8153; scalar/EXISTS/IN/ANY/SOME/ALL subqueries with correlation (512, 116); derived tables, CTEs incl. recursive + MAXRECURSION (530), CROSS/OUTER APPLY; UNION/EXCEPT/INTERSECT + ORDER BY (104, 205); TOP WITH TIES/PERCENT (1062); window functions (ROW_NUMBER/RANK/DENSE_RANK/NTILE/LAG/LEAD/FIRST_VALUE/LAST_VALUE/PERCENT_RANK/CUME_DIST, aggregates OVER with ROWS frames); OPENJSON (default + WITH) and STRING_SPLIT (ordinal); SELECT INTO; FOR JSON PATH/AUTO; `SELECT @v = … FROM`
- [x] `AT TIME ZONE` (2026-10-03, `harness/corpus/timezone/`, msduck `at-time-zone*`: 136 cases): all 141 Windows zones over years 1–9999, rules fitted to and checked against a SQL Server dump (`scripts/gen-timezones.py`, docs/reference/at-time-zone.md); local input in Volgograd 2020 and Samoa 2009 raises 50100. Open: sql_variant arguments (bitsql lacks sql_variant: 2715 instead of 8116), `datetimeoffset + nvarchar` reports 8117 instead of 402
- [ ] Query language gaps: two-error binds (8155 + 207), RANGE frames with offsets, DISTINCT window aggregates, FOR JSON AUTO with joins (nesting), FOR XML, PIVOT/UNPIVOT, SELECT INTO identity propagation, CI-equal GROUP BY spelling for heap plans (see fidelity traps)
- [~] INSERT (VALUES/SELECT/DEFAULT VALUES, defaults, identity, IDENTITY_INSERT, computed, rowversion), UPDATE (compound SET, DEFAULT), DELETE, statement-level rollback. OUTPUT (incl. INTO), UPDATE/DELETE FROM/TOP/aliases, MERGE (all clause families, 8672, TOP, OUTPUT $action). Missing: MERGE with CTE, MERGE on a table with triggers (50100)
- [~] Constraints: NOT NULL 515, PK/UNIQUE 2627, unique index 2601, CHECK 547, FK 547 both directions, truncation 2628, identity not rolled back. Missing: cascades, NOCHECK, messages verified against captures
- [~] Index seeks: `Filter(Scan)` whose WHERE pins every column of a unique, unfiltered index with `col = literal/variable/outer column` of the column's own type looks the key up (`exec/plan.mbt seek_rows`, `Session::seek`); the full predicate is re-applied, so results equal a scan. 10k rows: PK select 1.76 → 0.23 ms, PK update 2.4 → 0.12 ms. Equi-joins on `left.col = right.col` (same type) sort the inner side once and binary-search per outer row with the same comparison as `=`, re-checking the full ON predicate (10k × 10k join: 40 ms). Missing: range seeks, non-unique index seeks
- Gate: first tests move to the emulator allowlist.

## Phase 5: procedural

- [ ] Scope stack, variables, temp tables, table variables
- [~] Procs (session-level registry): RPC by name and EXEC in batches, params with defaults, OUTPUT, return status. Missing: store modules/sys visibility (catalog agent), nested scope rules for temp tables
- [x] Dynamic SQL (`sp_executesql` via RPC and in batches, `EXEC(@sql)`), DONEINPROC/DONEPROC framing, return status = last @@ERROR
- [~] Prepared statements: sp_prepare / sp_execute / sp_prepexec / sp_unprepare (8179) work with tedious prepare/execute. Missing: metadata emitted at prepare time (msduck: COLMETADATA + ORDER without rows) — unverified
- [~] TRY/CATCH with captured completion tokens, THROW/rethrow, RAISERROR (formatting, SETERROR, 2787), @@ERROR per statement, statement-level rollback, XACT_ABORT (doom in TRY, rollback outside), 3930 on writes/COMMIT when doomed, 3998 at request end, savepoints (SAVE/ROLLBACK TRAN name), 266 after EXEC; temp tables roll back, table variables don't. Missing: verification against gaps-transactions captures
- [x] Cursors: STATIC snapshot, FAST_FORWARD/default read from a snapshot with an Emulator error if base tables change while open; LOCAL/GLOBAL; FETCH NEXT/PRIOR/FIRST/LAST/ABSOLUTE/RELATIVE; @@FETCH_STATUS, @@CURSOR_ROWS; captured CurCmd codes. DYNAMIC/KEYSET/FOR UPDATE raise Emulator errors
- [~] Triggers (session/trigger.mbt, corpus `triggers/`): AFTER and INSTEAD OF for INSERT/UPDATE/DELETE, inserted/deleted pseudo-tables (newest first), UPDATE(col), TRIGGER_NESTLEVEL(), nesting (217 at 32), no direct recursion, NOCOUNT/SET restored, XACT_ABORT implied, implicit transaction for autocommit statements, ROLLBACK in trigger → 3609 batch abort, OUTPUT without INTO → 334. Missing: MERGE firing triggers, COLUMNS_UPDATED(), sp_settriggerorder, RECURSIVE_TRIGGERS ON, DDL/logon triggers, identity values of INSTEAD OF INSERT rows (unverified), errors inside triggers beyond XACT_ABORT semantics (uncaptured)
- [~] JSON: `core/json` implements JSON_VALUE, JSON_QUERY, ISJSON (types, depth 13606), OPENJSON default schema, path parsing (lax/strict, keys, quoted keys, indexes), passing all msduck boundary captures; OPENJSON WITH schema, FOR JSON PATH/AUTO and binder wiring done (query corpus). Missing: wildcards/advanced accessors, JSON_MODIFY
- [~] Scalar built-ins (`bind/fn_*.mbt`, `exec/fn_*.mbt`, corpus `harness/corpus/functions`, 987 captured cases, 968 pass): date/time (DATEADD, DATEDIFF(_BIG), DATEPART, DATENAME, YEAR/MONTH/DAY, EOMONTH, *FROMPARTS, TODATETIMEOFFSET, SWITCHOFFSET, ISDATE, DATETRUNC), string (STUFF, PATINDEX, CONCAT_WS, STR, QUOTENAME, STRING_ESCAPE, TRANSLATE, SOUNDEX, DIFFERENCE, FORMAT en-US subset, collation-aware TRIM/REPLACE/CHARINDEX, folded result lengths), math (ROUND, POWER, trig, LOG, DEGREES/RADIANS, RAND = SQL Server's generator), CHOOSE, GREATEST/LEAST, ISNUMERIC, HASHBYTES, CHECKSUM/BINARY_CHECKSUM (integers, strings for BINARY_CHECKSUM). Missing: DATE_BUCKET, SET DATEFIRST (fixed 7), non-ISO date text (ISDATE('Jan 5 2024')), FORMAT cultures other than en-US, CHECKSUM of text/decimal, COMPRESS, SQL_VARIANT_PROPERTY (needs sql_variant), HOST_NAME/SUSER_SNAME/USER_NAME, NEWSEQUENTIALID in defaults (302 elsewhere is done)
- Gate: all non-concurrency tests on the emulator.

- [~] Sequences (session/sequence.mbt, corpus `sequence/`): CREATE/ALTER (RESTART [WITH], INCREMENT, MIN/MAX, CYCLE, CACHE)/DROP SEQUENCE, NEXT VALUE FOR in SELECT, VALUES, DEFAULT constraints and variables; values not transactional; 11702/11703/11719/11721/11728 (batch abort)/11729/15151/2714/3701; flags 0. Missing: one value per row for repeated references of a sequence (raises 50100), sys.sequences (sql_variant columns), sp_sequence_get_range, decimal precision > 18

- [x] Identity/permission functions for the single `sa` login (USER_NAME, USER_ID, SUSER_NAME/SNAME/ID/SID, CURRENT_USER, SESSION_USER, USER, SYSTEM_USER, ORIGINAL_LOGIN, APP_NAME and HOST_NAME from LOGIN7, IS_SRVROLEMEMBER, IS_MEMBER, IS_ROLEMEMBER, HAS_DBACCESS, DATABASE_PRINCIPAL_ID, PERMISSIONS()), CONTEXT_INFO / SET CONTEXT_INFO (corpus `misc/`). SESSION_CONTEXT waits for sql_variant
- [x] SET statements (session/set_options.mbt, corpus `set/`): captured CurCmds per option; NOCOUNT, XACT_ABORT, DATEFIRST (DATEPART week/weekday, DATETRUNC week, @@DATEFIRST), LOCK_TIMEOUT (@@LOCK_TIMEOUT), DEADLOCK_PRIORITY (victim choice), CONTEXT_INFO, isolation level take effect; @@OPTIONS reflects NOCOUNT/XACT_ABORT. Non-default values bitsql does not model raise 50100 instead of being ignored: QUOTED_IDENTIFIER OFF, ANSI_NULLS/ANSI_PADDING/ANSI_WARNINGS/CONCAT_NULL_YIELDS_NULL/ANSI_NULL_DFLT_ON OFF, IMPLICIT_TRANSACTIONS/NUMERIC_ROUNDABORT/CURSOR_CLOSE_ON_COMMIT/NOEXEC/FMTONLY/PARSEONLY/SHOWPLAN_*/STATISTICS ON, ROWCOUNT ≠ 0, TEXTSIZE other than the maximum, DATEFORMAT other than mdy, LANGUAGE other than us_english
- [x] RESETCONNECTION (tedious `connection.reset()`): rollback + ENVCHANGE RESETACK, temp tables, cursors, SET options, context info and session app locks reset (captured; harness test/reset.test.mjs)
## Phase 6: concurrency

- [x] Transactions over persistent roots (BEGIN/COMMIT/ROLLBACK, ENVCHANGE 8/9/10, statement-level rollback). Concurrent writers merge: COMMIT re-applies the transaction's row/object changes onto the newest committed state (`Db::rebase`), and READ COMMITTED statements refresh their view the same way. 50107 remains only for a conflicting change that no lock prevented (e.g. DDL racing DML)
- [~] Lock manager wired (decisions.md: request restart): X on modified/inserted keys, UPDLOCK/HOLDLOCK/SERIALIZABLE/XLOCK reads lock the PK point or whole table, statement vs transaction durations, release on commit/rollback/statement end; parked requests re-run in the same handle call. Unhinted reads take S (statement duration under READ COMMITTED, transaction under REPEATABLE READ/SERIALIZABLE; none under NOLOCK/READ UNCOMMITTED/SNAPSHOT), including subqueries in WHERE/IF/WHILE. SET LOCK_TIMEOUT (0 immediate, n via host timers) → 1222 + 3621, statement-level. Corpus `locking/` (8 multi-connection captures). Missing: key-range locks for SERIALIZABLE beyond PK points/whole table, secondary-index seeks (reads lock the whole table unless the WHERE pins the PK), FK S-locks, SNAPSHOT update conflicts (3960), READ_COMMITTED_SNAPSHOT
- [x] Deadlocks: wait-for cycle detection; on equal cost the session waiting longest is the victim (captured), gets 1205 (state 51, class 13) then ENVCHANGE rollback and DONE 253; DEADLOCK_PRIORITY not implemented
- [x] Application locks: sp_getapplock / sp_releaseapplock (Session and Transaction owners, all five modes, @LockTimeout incl. 0 → -1 and waits → 1, reference counts), APPLOCK_MODE, APPLOCK_TEST; the procedures' internal DONEINPROC sequences reproduced per path (corpus `applock/`, incl. Prisma Migrate's call). Deadlock victim returns -3 (unverified)
- [x] WAITFOR DELAY/TIME: the request parks with a host timer; its re-run passes completed waits (CurCmd 243, captured). ATTENTION cancels it
- [x] Deterministic mode + replay (event log; scheduling is deterministic by construction)
- [x] `emulator.snapshot` / `emulator.restore` (all databases, identity counters, @@DBTS, procs; O(1) via immutable Db values)
- Gate: the MSSQL CI job is removed; nightly cross-check remains.

## Databases

- [x] Multiple databases: CREATE/DROP DATABASE (203/204, 1801, 3701), USE (911), login to unknown database → 4060 + 18456 (msduck capture); host `--database NAME`, `--auto-create-databases`

## Phase 7: packaging

- [x] Native release binary 2.7 MB (libc only); `Dockerfile` on distroless/cc: **26.4 MB image, ~0.8 MB RSS idle** (2026-10-03; 10k-row table ≈ 8 MB RSS). Possible next: static musl build on scratch (~3 MB image)

## Limiting factor

For first value: phases 2–3, the protocol plus full parser coverage, because no
test can run until `tedious` connects and migrations succeed. For the whole
project: the breadth of transaction and error semantics in phases 5–6.

## Risks

| Risk | Mitigation |
| --- | --- |
| False greens from subtle semantic gaps | Differential harness; nightly cross-check; explicit errors for unsupported features |
| MoonBit toolchain churn | Pre-1.0 language: async churn confined to the ~150-line host, the core uses no async; versions pinned, docs vendored with a rerunnable script |
| Scope creep from rarely used features | Harness failure ranking drives priorities |
| Long tail delays the RAM payoff | Allowlist routing gives speed gains early |
| Lock behavior diverges due to access paths | Seek on sargable predicates; conservative `WholeTable` fallback |
| Target app suite not available in this repo | Build the corpus from msduck captures + traps first; capture the app as soon as access is given |
