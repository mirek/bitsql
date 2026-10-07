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
- [x] RPC decode: proc id / name, params with TYPE_INFO and values (incl. PLP), table-valued parameters (TVP_TYPE 0xF3, `tds/tvp.mbt`); dispatch of sp_executesql/sp_prepexec is in session work
- [x] ATTENTION (2026-10-04): a request parked in WAITFOR or a lock/applock wait is re-run in cancel mode and stops at that wait: its own response (captured cancel completion: held DONE → DONE(ERROR), RPC DONEPROC(ERROR, 224), 3621 for DML lock waits, statement rollback, open transaction kept, XACT_ABORT rollback), then DONE_ATTN (CurCmd 253) as a second message; idle ATTENTION gets DONE_ATTN only. Tests: engine_test, harness `test/attention.test.mjs` (mssql requestTimeout + pool reuse, lock-blocked UPDATE, tedious cancel() transaction state). Still missing: cancelling a long CPU-bound request (execution is not time-sliced; its response goes out before the ATTENTION is read). Noticed: `XACT_STATE()` next to a table read returns 1 outside a transaction on SQL Server (not emulated, see TRY/CATCH item)
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
  RAISERROR/EXEC/cursors/transactions, tedious's login SET batch, PIVOT/UNPIVOT, TABLESAMPLE,
  JSON_OBJECT/JSON_ARRAY). Missing:
  WITH XMLNAMESPACES, GROUP BY ALL / WITH ROLLUP, FOR SYSTEM_TIME, the named
  `WINDOW` clause, `.WRITE`, xml/CLR method calls (`x.value(...)` parses as a
  qualified call), `type::Method()`, DDL triggers (`ON DATABASE`), CREATE/ALTER DATABASE,
  RAISERROR/EXEC/cursors/transactions, tedious's login SET batch). Missing: PIVOT/UNPIVOT,
  WITH XMLNAMESPACES, GROUP BY ALL / WITH ROLLUP, TABLESAMPLE, FOR SYSTEM_TIME,
  `.WRITE`, CLR method calls (xml methods parse since
  2026-10-03), `type::Method()`, DDL triggers (`ON DATABASE`), CREATE/ALTER DATABASE,
  `EXECUTE AS` statement, `EXEC ... AT`, legacy `RAISERROR n 'msg'`.
  2026-10-04: ENABLE/DISABLE TRIGGER statements, `SET @cursor = CURSOR ...`,
  `WHERE CURRENT OF GLOBAL c`, DBCC statements parse. 2026-10-04 (tail round 4):
  legacy `FROM t (NOLOCK)` / `t a (NOLOCK)` hints (one hint; `t (INDEX(0))` is 1018),
  table variables take no hints (319 / 156), ALTER INDEX, BACKUP and RESTORE
  statements, niladic functions with parentheses (102), `NEXT VALUE FOR … OVER`
  raises 50100.
  Error numbers 102/156/111/319/10713 follow captures where available; trailing statements
  after CREATE VIEW/FUNCTION and the THROW-after-unterminated rule are unverified guesses.
- [~] Parse differential over the corpus: 1707/1707 batches agree with SQL Server (`npm run parse-diff`); `parsecheck FILE...` ready for the target codebase (needs app repo)
- [~] rowversion and identity (2026-10-04, msduck gaps-rowversion_identity 190/193, corpus `stmts/rowversion-identity-rules`): `timestamp` as a column type name and as a bare column, one per table (2738), no defaults (1755), INSERT/UPDATE rules (273/272), ALTER ADD fills rows, MIN_ACTIVE_ROWVERSION NOT NULL; identity type checks (2749/8147/1754), overflow 8115 + 3606 (ends the batch), SCOPE_IDENTITY/@@IDENTITY reset by inserts into tables without identity, decimal explicit values, IDENTITY_INSERT 8106/8107. Missing: identity seeds/increments beyond bigint (50100, #098-#100), 273 as a whole-batch compile error, SELECT INTO identity columns
- [~] Types: int family, bit, decimal, (n)varchar, datetime2, datetimeoffset, uniqueidentifier, rowversion
      (`src/core/types`: values, precedence/result types, CAST/CONVERT, checked arithmetic,
      comparison and collations, emulator error table. Missing: `harness/corpus/traps` cases
      for the new type traps and oracle captures for the unverified choices listed in the
      t-sql skill findings (no MSSQL was run for this work),
      collations other than Latin1_General/SQL_Latin1, CHECKSUM of decimal/sql_variant/
      Windows-collation and UTF-8 strings (50100).
      Done 2026-10-04 (docs/reference/conversion-styles.md, lob-types.md, hash-compress.md;
      `harness/corpus/conversion`): every date/time → character CONVERT style for all six temporal
      types incl. Hijri 130/131 (Kuwaiti algorithm, 9814), 281/8114 for invalid/inapplicable
      styles, every character → date/time input style (9809, Hijri input), run-time CONVERT
      styles (`@s`, NULL → NULL, 8116 for non-integers), float/real/money styles (all numbers),
      float/real/money/decimal ↔ binary storage bytes, binary ↔ character style truncation and
      9809, text/ntext/image (wire TEXT/NTEXT/IMAGE, catalog, conversions, 402/306/421/5335/
      8116/8117/2739/1919), COMPRESS (byte-exact zlib level 6) / DECOMPRESS, CHECKSUM /
      BINARY_CHECKSUM per type, collation-aware LIKE / PATINDEX, CHARINDEX ignorables and `_SC`
      positions, SET ANSI_WARNINGS OFF (warnings only), ROWCOUNT_BIG, CURSOR_STATUS,
      COLUMNS_UPDATED, NTILE 4116/4195, COUNT(NULL) 8117, CASE of NULLs 8133, 1007.
      Done 2026-10-03: character strings → date/time in every us_english/mdy shape (legacy datetime
      parser vs new date/datetime2 parser, 241/242/295/9807, ISDATE, implicit conversions) and
      string → date CONVERT styles 0-5/10/11/20/21/101-105/110-112/120/121/126/127
      (docs/reference/date-strings.md, `harness/corpus/datestrings`, ~3,600 captured cases;
      other styles raise 50105).
      Done 2026-10-03: CP1252 best fit (captured table), collation precedence
      468/4191/451 incl. derived tables and set operations, string-expression
      metadata (corpus `collation/`). Open: multiple 451 errors per statement,
      451 for ORDER BY / GROUP BY keys, sql_variant / SQL_VARIANT_PROPERTY)
- [ ] Collation follow-up (2026-10-06): existing default-collation dotted/dotless
      I ordering gap and unsupported Turkish_CI_AS now have reduced oracle
      probes (`traps/dotted-dotless-i-order.sql`, `traps/turkish-i-order.sql`).
      Both remain outside the allowlist; details in `fidelity-traps.md`.
- [x] Store: `PMap` + `core/store` Db (tables, rows by rowid, unique/non-unique index maps incl. `IS NOT NULL` filtered indexes, modules, schemas, constraint object ids, stable column_id / index_id)
- [~] DDL execution: CREATE/DROP TABLE (columns, NULL/NOT NULL, IDENTITY, DEFAULT, computed, PK/UNIQUE/CHECK/FK incl. self-reference), temp tables, table variables, TRUNCATE; ALTER TABLE ADD (columns incl. DEFAULT/WITH VALUES/identity/computed, constraints WITH CHECK/NOCHECK), DROP COLUMN/CONSTRAINT [IF EXISTS], ALTER COLUMN, CHECK/NOCHECK CONSTRAINT, ENABLE/DISABLE TRIGGER; CREATE/DROP INDEX (unique → 1505 on build, filtered); CREATE/DROP SCHEMA; CREATE/ALTER/DROP VIEW/PROCEDURE/FUNCTION/TRIGGER registered as store Modules (sys.sql_modules, OBJECT_ID); sp_rename (tables, columns; 2026-10-04 indexes, constraints and the 15336/15223/15004/15248/15249/15225 argument errors in their captured order); ALTER INDEX DISABLE/REBUILD/REORGANIZE (2727, 1973, 1505 on REBUILD); DROP INDEX lists (159, 3701 states 6/7); column type checks 183/2750/1001/1002; errors 2714/1750, 1779, 4902, 4924, 3728/3727, 5074/4922, 3725, 4917/4916, 4920, 4901, 1088, 1911, 1913, 3723, 3701, 15151, 2759, 3729 captured (corpus `catalog/`). SELECT from views binds the stored query like a derived table (Catalog.view hook). DML through views: see the INSERT/UPDATE/DELETE item. Index ids of a new table: clustered 1, the others in reverse order of definition (captured). 2026-10-05: inline INDEX options (UNIQUE, CLUSTERED demoting a default-clustered PK, INCLUDE, WHERE, WITH; 8112) and a trailing comma in CREATE TABLE (not table variables/types, TVF tables or ALTER ADD: 102). Done 2026-10-04: ALTER COLUMN / DROP COLUMN dependents per kind and in SQL Server's order (filtered-index predicates block every ALTER COLUMN, computed columns too, checks only type/collation changes, keys NULL→NOT NULL; corpus `catalog/alter-column-dependents`, `catalog/alter-column-filtered-index`). Missing: CREATE/DROP STATISTICS (a 156 syntax error today; filtered statistics block ALTER COLUMN with "The statistics 'x' is dependent…"), the position of self-referencing FKs in DROP COLUMN's 5074 list, filtered UNIQUE indexes other than AND-ed comparisons/IS [NOT] NULL, ALTER TABLE ADD INDEX, sp_rename of databases/types/statistics (50100), disabling a clustered index (50100), `sysname` user_type_id 256 in sys.columns, ALTER TABLE … REBUILD, schema-bound dependents and name clashes in ALTER SCHEMA TRANSFER (50100). Done 2026-10-04 (tail5 fork B2): `ALTER SCHEMA … TRANSFER` OBJECT::/TYPE:: (15151/15530/33144/2710), the sticky `lob_data_space_id`
- [~] Virtual `sys.*` / `INFORMATION_SCHEMA` views (scope 2, rows computed from the Db; descriptors generated from captures by `scripts/gen-sysviews.py`): sys.objects (+118 seeded system objects), tables, views, procedures, columns, types, schemas, indexes, index_columns, key_constraints, foreign_keys, foreign_key_columns, check_constraints, default_constraints, computed_columns, sql_modules, triggers, databases, time_zone_info, identity_columns, sequences (sql_variant columns), partitions and allocation_units (2026-10-05, modelled page counts, decisions.md); INFORMATION_SCHEMA TABLES/COLUMNS/ROUTINES/VIEWS/TABLE_CONSTRAINTS/KEY_COLUMN_USAGE/REFERENTIAL_CONSTRAINTS, and (2026-10-04) PARAMETERS/CHECK_CONSTRAINTS/CONSTRAINT_COLUMN_USAGE/SCHEMATA. Catalog functions OBJECT_ID (types, `tempdb..#t`), OBJECT_NAME, OBJECT_SCHEMA_NAME, SCHEMA_ID/NAME, COL_LENGTH, COL_NAME, COLUMNPROPERTY, OBJECTPROPERTY, INDEXPROPERTY, TYPE_ID/NAME, DB_ID, DB_NAME(id), IDENT_CURRENT/SEED/INCR, OBJECT_DEFINITION, HAS_PERMS_BY_NAME. 2026-10-04: `tempdb.sys.*` / `tempdb.INFORMATION_SCHEMA.*` list the session's temp tables under their padded internal names (msduck gaps-temp_tables, corpus `stmts/temp-*`); `sys.dm_exec_cursors(session_id)`. 2026-10-04 (tail round 4): sys.system_objects (2637 rows) and sys.system_columns (11569) dumped from the oracle (`harness/src/dump-system-catalog.mjs` → `scripts/system-catalog/*.tsv` → `session/sysviews_system_data.mbt`), sys.all_objects / sys.all_columns, sys.database_files, sys.server_principals, table types as `TT_` rows of sys.objects, user object ids from 1221579390. Missing: system-table rows in sys.columns/indexes, other catalog views (50100), tempdb's own system objects, OBJECTPROPERTYEX
- [x] User-defined types (2026-10-03, corpus `tabletypes/`, `session/tabletypes.mbt`): CREATE TYPE … AS TABLE (columns, PK/UNIQUE/CHECK/DEFAULT/IDENTITY, inline INDEX; no DONE of its own), alias types `CREATE TYPE t FROM base [NULL|NOT NULL]` (columns, variables, parameters; NOT NULL default; sys.columns user_type_id), DROP TYPE [IF EXISTS], `DECLARE @t <table type>`, sys.types / sys.table_types rows, type tables in sys.columns / sys.indexes, TYPE_ID / TYPE_NAME; errors 219, 218, 222, 2717+225, 2715 (+2724 for DECLARE), 243 (CAST to an alias/unknown type), 3732, 2705/8110 in table types, 137 for a table variable used as a scalar. Missing: CREATE TYPE … EXTERNAL NAME (CLR), alias types of alias types, COLLATE on alias-typed columns, table types with FOREIGN KEY or named constraints (SQL Server rejects them; bitsql does not check), dependencies of type tables in sys.objects (none in SQL Server either)
- [x] Table-valued parameters (2026-10-03, corpus `tabletypes/readonly-params`, `tvp-rpc`, harness `test/mssql-tvp.test.mjs`): READONLY parameters of procedures, scalar/inline/multi-statement functions and sp_executesql (shared with the caller's table variable; no argument = empty table), TDS TVP_TYPE 0xF3 decode (`tds/tvp.mbt`: TVP_TYPENAME, column metadata, optional ORDER_UNIQUE/COLUMN_ORDERING, TVP_ROW, NULL table) for sp_executesql and procedure RPCs, constraint checks while loading (2627 at line 0 + 3621), 352, 346, 10700 (CREATE and dynamic SQL), 206 for a scalar argument (line 0, DONEPROC without RETURNSTATUS), sys.parameters (is_readonly, system_type_id 243). Missing: TVPs of table types with IDENTITY or computed columns (50100), TVP columns that differ from the type (50100), sql_variant TVP columns (tedious cannot send them)
- [x] Synonyms (2026-10-03, corpus `tabletypes/synonyms`, `session/synonyms.mbt`): CREATE/DROP SYNONYM [IF EXISTS] (no DONE for CREATE; DROP CurCmd 329), resolution in SELECT (synonym name qualifies columns), INSERT/UPDATE/DELETE, EXEC and RPC by name, functions; sys.synonyms, sys.objects type SN, OBJECT_ID; 5313, 2714 state 8, 2760, 3701, 3705 both ways. Missing: synonyms of objects in other databases or servers (50100), synonyms as DML targets of views
- [x] sp_help family (2026-10-03, corpus `sysprocs/`, `session/sysprocs_help.mbt`; batch, sp_executesql and RPC by name): sp_help (tables incl. constraints and referencing FKs, views, procedures, alias/table types, 15009), sp_helptext (CR LF / 255-character lines, 15197, 15009), sp_columns (ODBC 2 type map captured for every type), sp_tables, sp_pkeys, sp_fkeys, sp_who for the caller's spid and unknown logins (15007), with the procedures' internal DONEINPROC 192/193 sequences per path. Missing (50100): sp_help without arguments and of functions/triggers/synonyms/sequences, alias-typed columns in sp_help/sp_columns, `%`/`[` patterns, other databases, sp_who without arguments or for other sessions/logins, sp_helptext @columnname, sp_tables @table_type, system objects in sp_tables
- [~] User-defined functions (2026-10-03, `harness/corpus/udf/*`, `session/udf.mbt`, `bind/udf.mbt`): scalar UDFs in any expression (SELECT/WHERE/ORDER BY, SET/DECLARE, UPDATE, computed columns, defaults, CHECK), argument conversion, DEFAULT arguments, RETURNS NULL ON NULL INPUT, recursion with 217 at level 33, errors at the caller's line; inline TVFs (parameters, CROSS/OUTER APPLY); multi-statement TVFs (return table, 3621 after an error); `EXEC [@r =] dbo.scalar_fn`; CREATE FUNCTION checks 443/444/455/178/1075/2772; binding errors 195/4121/313/8144/206/208/216/317. Missing: compile-time errors (313/8144/4121) do not abort the statements *before* them in the batch (SQL Server compiles the whole batch first), DROP FUNCTION referenced by a computed column (3729), INFO 2007 for EXEC of a missing procedure in a body, cursors and EXEC inside function bodies (50100), sys.columns/sys.parameters rows for functions, SCHEMABINDING checks
- Gate: all migration scripts run green.

## Phase 4: DML and access paths

- [~] Binder + IR (core/bind, core/ir) with captured metadata rules; Semantics record not extracted yet (T-SQL rules inline)
- [~] Executor: scan, filter, project, nested-loop joins (inner/left/right/full/cross), sort, limit, distinct, union all, values, streaming result sets (rows before a run-time error stay sent)
- [x] Query language (2026-10-03, `harness/corpus/query/*`): aggregates (COUNT/COUNT_BIG/SUM/AVG/MIN/MAX/STRING_AGG WITHIN GROUP/STDEV/VAR, DISTINCT), GROUP BY expressions, HAVING, ROLLUP/CUBE/GROUPING SETS + GROUPING/GROUPING_ID, INFO 8153; scalar/EXISTS/IN/ANY/SOME/ALL subqueries with correlation (512, 116); derived tables, CTEs incl. recursive + MAXRECURSION (530), CROSS/OUTER APPLY; UNION/EXCEPT/INTERSECT + ORDER BY (104, 205); TOP WITH TIES/PERCENT (1062); window functions (ROW_NUMBER/RANK/DENSE_RANK/NTILE/LAG/LEAD/FIRST_VALUE/LAST_VALUE/PERCENT_RANK/CUME_DIST, aggregates OVER with ROWS frames); OPENJSON (default + WITH) and STRING_SPLIT (ordinal); SELECT INTO; FOR JSON PATH/AUTO; `SELECT @v = … FROM`
- [x] `AT TIME ZONE` (2026-10-03, `harness/corpus/timezone/`, msduck `at-time-zone*`: 136 cases): all 141 Windows zones over years 1–9999, rules fitted to and checked against a SQL Server dump (`scripts/gen-timezones.py`, docs/reference/at-time-zone.md); local input in Volgograd 2020 and Samoa 2009 raises 50100. Open: sql_variant arguments (bitsql lacks sql_variant: 2715 instead of 8116), `datetimeoffset + nvarchar` reports 8117 instead of 402
- [x] Analytic queries (2026-10-03, `harness/corpus/analytic/`, docs/reference/analytic.md): PIVOT/UNPIVOT (implicit grouping, IN-value conversion 8114+473, 265/8156/277/8167/406/195), PERCENTILE_CONT/DISC (8726/8727/10751-10758), window frame validation (RANGE offsets are 4194 in SQL Server too; 4193, 10752, 10756, literal-only offsets), STRING_AGG separator/WITHIN GROUP/ROLLUP/9829 checks, CHECKSUM_AGG (XOR, int only), APPROX_COUNT_DISTINCT (exact up to 30 distinct values, else 50151), GENERATE_SERIES (type rules, 5373/8116+206, 4199), TABLESAMPLE 0/100 PERCENT (else 50150), PARSE/TRY_PARSE (culture table since 2026-10-04, a captured date subset; 50171/50172), DATE_BUCKET (50170 for int32-overflowing month widths), `-2147483648` as int. Also verified by the msduck-runs percentile-*, json-constructors, parse-try-parse, datetrunc-bucket and string-agg captures (702 newly passing). Open: PIVOT row order with several grouping columns is plan-dependent (text PIVOT 488/8117, PERCENTILE_DISC over xml 305, float literal 337/168 and whitespace in float text done 2026-10-04); 8734 as a whole-batch compile error
- [ ] Query language gaps: two-error binds (8155 + 207), DISTINCT window aggregates, FOR XML, SELECT INTO identity propagation, CI-equal GROUP BY spelling for heap plans (see fidelity traps). FOR JSON AUTO nesting and FOR JSON in subqueries done 2026-10-04 (docs/reference/json.md)
- [x] FOR XML and the xml type (2026-10-03, corpus `xml/`, 328/339 cases, docs/reference/xml.md): FOR XML RAW/AUTO/PATH at top level (NTEXT chunks, TYPE) and in subqueries (STUFF idiom, TYPE + value()), ROOT, ELEMENTS [XSINIL], BINARY BASE64, captured name/order errors; FOR JSON in subqueries; xml variables/columns/parameters, CAST/CONVERT (styles 0/1, binary UTF-8/UTF-16), parse errors with positions, comparison/operator errors, sys.columns/INFORMATION_SCHEMA; value/query/exist/nodes with an XQuery path subset, arithmetic, sql:variable/sql:column; batch compile errors for table-free statements (precheck_xml)
- [ ] xml gaps (emulator 50109 unless noted): FOR XML EXPLICIT, XMLSCHEMA/XMLDATA, `modify()`, XQuery namespaces (`declare namespace`, prefixed names), FLWOR, casts, functions beyond the subset, typed xml (schema collections), DATALENGTH(xml), DTDs (style 2), AUTO without BINARY BASE64 on binary columns; ORDER BY a variable select item reports 305 instead of 1008; xml compile errors in statements over tables still run the earlier statements of the batch
- [ ] Query language gaps: two-error binds (8155 + 207), RANGE frames with offsets, DISTINCT window aggregates, PIVOT/UNPIVOT, SELECT INTO identity propagation, CI-equal GROUP BY spelling for heap plans (see fidelity traps). FOR JSON AUTO with joins and FOR JSON nested in FOR JSON done 2026-10-04
- [~] INSERT (VALUES/SELECT/DEFAULT VALUES, defaults, identity, IDENTITY_INSERT, computed, rowversion), UPDATE (compound SET, DEFAULT; 2026-10-05 compat report: all eight compound operators as `x = x op e` in UPDATE/MERGE/SET/SELECT @v, bitwise operand rules 402/8117, 264 duplicate SET column, corpus `dml/compound-assignment`), DELETE, statement-level rollback. OUTPUT (incl. INTO), UPDATE/DELETE FROM/TOP/aliases, MERGE (all clause families, 8672, TOP, OUTPUT $action). 2026-10-03 (corpus `output/`, `views/`, msduck `output-*`): OUTPUT COLMETADATA before execution and rows streamed up to a failing row, OUTPUT name scoping (target hidden, sources qualified only, `x.*`, 107/404/207), target resolution against FROM (single aliased occurrence, 8154), INFO 3621 after any run-time DML error, DONE 253 for batch-ending DML errors without OUTPUT, INSERT/UPDATE/DELETE through views, CTEs and derived tables (joins when one base table is modified, nested views, WITH CHECK OPTION 550, 4403/4405/4406/4421), WITH on INSERT/UPDATE/DELETE. 2026-10-04 (msduck-runs merge-top-percent 109/109, gaps-merge 40/41, corpus `stmts/merge-hints`): MERGE TOP (n) PERCENT (1031/1014), MERGE with a CTE source, MERGE on tables with INSTEAD OF triggers (5316), MERGE compile errors 8102/271/109/110/213, 8672 streaming and rollback order, table hints on DML targets (321, 1065), UPDATE/DELETE WHERE CURRENT OF (cursors item). Missing: MERGE into a CTE target, DML through views/CTEs with TOP, UNION or a nested WITH, views with INSTEAD OF triggers (all 50100), gaps-merge #008 (two syntax errors from one statement: the parser reports one)
- [~] Constraints: NOT NULL 515, PK/UNIQUE 2627, unique index 2601, CHECK 547, FK 547 both directions, truncation 2628, identity not rolled back. 2026-10-04 (msduck gaps-constraints/gaps-keys/gaps-computed, corpus `constraints/`, `session/fk_actions.mbt`): ON DELETE/UPDATE CASCADE, SET NULL, SET DEFAULT (recursive, computed columns recomputed, child CHECK/unique/FK checked), NO ACTION checked against the statement's final state (self-referencing DELETE of all rows), FOREIGN KEY SAME TABLE / SAME TABLE REFERENCE messages, no column for multi-column keys, UPDATE checks only constraints over the columns it sets, NOCHECK constraints neither act nor check; definition errors 1778/1753/1761/1762/1764/1715/1765/8139/1785 (cascade paths and cycles), 8168, 1046, 128, 257 for DEFAULT, 1759/4936 for computed columns, 1750 states; filtered UNIQUE indexes with AND-ed column comparisons; IGNORE_DUP_KEY (3604), FILLFACTOR, DROP_EXISTING, 155/1916/129/7999/1909/1919/8112, 1944/1945 key length warnings; IDENTITY_INSERT 544/545 at run time, 8101/264/339 at compile time, identity metadata flags 24 while ON, reverting at the end of a procedure/dynamic SQL. Missing: 1776 for a FOREIGN KEY whose referenced column list names a key's columns in another order (SQL Server 17.0.5005.3 rejects `REFERENCES fp (k, x)` against `PRIMARY KEY (x, k)`; bitsql accepts it, found 2026-10-04), NOT FOR REPLICATION semantics. 2026-10-05 (compat report 0.1.3 #7, corpus `triggers/cascade-*`, `instead-of-cascade-ddl`): AFTER triggers of tables changed by cascades fire (see Triggers); MERGE cascades captured (each key move takes its own ON DELETE / ON UPDATE action); 2113 / 1787 for INSTEAD OF DELETE/UPDATE triggers vs cascading foreign keys
- [~] Index seeks: `Filter(Scan)` whose WHERE pins every column of a unique, unfiltered index with `col = literal/variable/outer column` of the column's own type looks the key up (`exec/plan.mbt seek_rows`, `Session::seek`); the full predicate is re-applied, so results equal a scan. 10k rows: PK select 1.76 → 0.23 ms, PK update 2.4 → 0.12 ms. Equi-joins on `left.col = right.col` (same type) sort the inner side once and binary-search per outer row with the same comparison as `=`, re-checking the full ON predicate (10k × 10k join: 40 ms). 2026-10-04 (decisions.md, `npm run bench`): non-unique index seeks (not char/varchar keys), statement lookup indexes for repeated `col = outer` lookups on unindexed columns, uncorrelated subqueries memoized per statement (IN/NOT IN by binary search), sort-based GROUP BY/DISTINCT/UNION/EXCEPT/INTERSECT/COUNT(DISTINCT), FK checks and cascades through key indexes, MERGE matching through the equi-join index; every benchmark shape O(n log n) (20k rows: all under 1 s; were 18–440 s or over the work budget). Missing: range seeks; correlated non-equality subqueries still scan per outer row; ALL/ANY over a memoized set is still a linear loop per row (linguistic string comparison and sort keys allocate no per-character elements since 2026-10-05: packed elements in reused buffers, docs/design/performance.md)
- Gate: first tests move to the emulator allowlist.

## Phase 5: procedural

- [~] Scope stack, variables, temp tables, table variables. 2026-10-04 (msduck gaps-temp_tables 38/38, corpus `stmts/temp-*`): `db..#t` → tempdb with INFO 2701, 208 state 0 for a missing temp table, duplicate `CREATE TABLE #t` in a batch is compile-time 2714, local temp tables of procedures/dynamic SQL/sp_executesql RPCs dropped at module end, table variable DECLAREs are compile-time (loops, skipped branches). Missing: a procedure's temp table shadowing a caller's of the same name (2714 today)
- [~] Procs (session-level registry): RPC by name and EXEC in batches, params with defaults, OUTPUT, return status. 2026-10-04 (corpus `proc/*`; gaps-procedures 141/141, gaps-rpc-procedures 111/111, from 70 and 46): return status from the worst own error (10 - severity), RETURN NULL (282), module-ending vs batch-ending errors and their tokens, unwinding DONEPROC/DONEINPROC under a caller's TRY, ERROR_PROCEDURE(), EXEC errors (2812 state 62, argument errors at line 0, 8114 argument conversion, OUTPUT write-back 8114 state 2), positional OUTPUT and DEFAULT arguments, bare words, bare procedure call at batch start, 32-level limit (217), @@NESTLEVEL (+2 for sp_executesql), SET options revert after procedures/EXEC strings/sp_executesql/RPCs, NOCOUNT drops nested 224 DONEINPROCs, 266 for EXEC strings and sp_executesql, procedure RPCs (argument validation, client-typed RETURNVALUEs, system procedures by RPC), CREATE PROCEDURE compile checks (134/137/154/156), 2010, 3705, DROP PROC lists. Missing: store modules/sys visibility (catalog agent), nested scope rules for temp tables, INFO 2007 at CREATE for a missing callee, errors inside triggers (module rules not applied there)
- [x] Dynamic SQL (`sp_executesql` via RPC and in batches, `EXEC(@sql)`), DONEINPROC/DONEPROC framing, return status = last @@ERROR (sp_executesql) / procedure rule (EXEC string); argument validation 214/8144/8162/8178/8114 with their statuses (2026-10-04)
- [~] Prepared statements: sp_prepare / sp_execute / sp_prepexec / sp_unprepare (8179) work with tedious prepare/execute. 2026-10-04: EXEC sp_prepare / sp_execute / sp_unprepare in T-SQL (`session/prepare_exec.mbt`, corpus `tail/prepare-in-batch`): a single SELECT compiles at prepare time and sends COLMETADATA (+ ORDER) without rows, compile errors are the error + 8180, several statements / a syntax error / a procedure call prepare deferred (status 8182), 214 state 3 for @options = 0, 8179 states 4/8. 2026-10-04 (tail5 fork B2): prepare of DML, assignments, SET, PRINT, CREATE TABLE and BEGIN TRAN in T-SQL (DONEINPROC with the statement's CurCmd; `Session::compile_only`). Missing: named arguments, errors under TRY
- [~] TRY/CATCH with captured completion tokens, THROW/rethrow, RAISERROR (formatting, SETERROR, 2787), @@ERROR per statement, statement-level rollback, XACT_ABORT (doom in TRY, rollback outside), 3930 on writes/COMMIT when doomed, 3998 at request end, savepoints (SAVE/ROLLBACK TRAN name), 266 after EXEC; temp tables roll back, table variables don't. 2026-10-04: savepoint stack semantics (collation matching, consumption, transaction names, 6401/628/103/3914/3931) verified against msduck-runs `savepoint` (530/567, from 409; the rest: XACT_STATE() next to IDENT_CURRENT, identity values, ALTER DATABASE COLLATE); batch-aborting conversion errors roll back or doom the transaction; ERROR before the rollback ENVCHANGE. 2026-10-04 (msduck gaps-transactions 91/92, corpus `stmts/tx-*`): WAITFOR argument grammar and types (148 compile / 241 / 9815), DBCC USEROPTIONS (and 2526/2532/2583/195 for other DBCC forms; other known DBCC commands 50100), @@TRANCOUNT inside DML (max(@@TRANCOUNT, 1) + 1). Per-database collation for savepoint names and DBCC USEROPTIONS under READ_COMMITTED_SNAPSHOT done 2026-10-04 (settings). Missing: XACT_STATE() = 1 next to IDENT_CURRENT outside a transaction
- [x] Cursors (2026-10-04, `session/cursor.mbt`, msduck-runs `cursor` 83/87, corpus `stmts/cursor-*`): created types per SQL Server's implicit conversions (sys.dm_exec_cursors properties, 16956 under TYPE_WARNING); STATIC snapshots, KEYSET over one table (row ids + unique key at OPEN, values re-read, -2 / ROWSTAT 2 / blank values for deleted or re-keyed rows), DYNAMIC and FAST_FORWARD over one table (re-run per FETCH, positioned by the ordering tuple), FETCH results with ROWSTAT + TABNAME/COLINFO/ORDER, all FETCH orientations with 16911/16925/16924/16917/16905/16915/16916/16950, LOCAL scope per batch/module, GLOBAL per session, cursor variables (`SET @c = CURSOR …`, `SET @c = name`, CURSOR VARYING OUTPUT parameters, reference-counted DEALLOCATE), CURSOR_STATUS('variable'), @@CURSOR_ROWS (0 after the last opened cursor closes), positioned UPDATE/DELETE (CurCmd 125/126; 16929/16931/16932/16933/16947), 1048/1049 compile errors. Missing: keyset/dynamic cursors over joins or views read a snapshot and raise 50100 once a base table changed, positioned DML through them (50100), CURSOR_CLOSE_ON_COMMIT ON, cursors seen by other sessions' changes (multi-connection visibility uncaptured), sp_cursor* API procedures
- [~] Triggers (session/trigger.mbt, corpus `triggers/`): AFTER and INSTEAD OF for INSERT/UPDATE/DELETE, inserted/deleted pseudo-tables (newest first), UPDATE(col), TRIGGER_NESTLEVEL(), nesting (217 at 32), no direct recursion, NOCOUNT/SET restored, XACT_ABORT implied, implicit transaction for autocommit statements, ROLLBACK in trigger → 3609 batch abort, OUTPUT without INTO → 334. MERGE fires AFTER triggers per action clause present (also for zero rows; INSERT, UPDATE, DELETE order; captured). 2026-10-04 (msduck gaps-triggers 173/173): @@ROWCOUNT on entry, ROLLBACK paths (pseudo-tables empty afterwards, later writes autocommit), errors caught by an outer TRY, INSTEAD OF INSERT identity (0, nothing consumed), MERGE with INSTEAD OF triggers, MERGE 334 per performed event, definition errors 2714/111/2103/2110/2111/1034/8197, standalone ENABLE/DISABLE TRIGGER (1088 states 21/119). Missing: sp_settriggerorder, RECURSIVE_TRIGGERS ON, DDL/logon triggers, INSTEAD OF triggers on views (50100), triggers on a child whose clustered unique key a MERGE changes through a referential action (50100: SQL Server splits that update, `triggers/cascade-merge-unique-key` fails on purpose), TRIGGER_NESTLEVEL(object_id, …) arguments (ignored), ERROR_PROCEDURE() for errors raised in triggers (NULL, SQL Server names the trigger), pseudo-tables consume object ids (SQL Server's do not, so ids of objects created after a trigger fired differ). 2026-10-05: AFTER triggers on tables changed by FK cascades (`session/fk_triggers.mbt`, corpus `triggers/cascade-*`): all cascades first, then child triggers in reverse depth-first order (siblings by FK object_id, descending), then the statement's own; UPDATE triggers before DELETE triggers of one child, @@ROWCOUNT = the child's cascaded rows, UPDATE()/COLUMNS_UPDATED() = FK columns, nest level 1, errors/ROLLBACK undo the whole statement
- [~] JSON: `core/json` implements JSON_VALUE, JSON_QUERY, ISJSON (types, depth 13606), OPENJSON default schema, path parsing (lax/strict, keys, quoted keys, indexes), passing all msduck boundary captures; OPENJSON WITH schema, FOR JSON PATH/AUTO and binder wiring done (query corpus). JSON_OBJECT/JSON_ARRAY (NULL/ABSENT ON NULL) and JSON_MODIFY (in-place text edits, append, lax/strict, NULL removal) done 2026-10-03 (`harness/corpus/json2/`). Done 2026-10-04 (`harness/corpus/json3/`, docs/reference/json.md; the msduck json-advanced-path, json-extraction-wildcard, isjson-*, unicode-json-storage and gaps-json_string files pass fully): advanced accessors (`.*`, `[*]`, `[a to b]`, 13659/13660), the full path lexer (13607 states, whitespace), max-type error states, JSON errors ending the batch, lazy 13606, ISJSON type constraints, JSON_PATH_EXISTS, FOR JSON AUTO nesting and raw JSON columns, JSON_ARRAYAGG/JSON_OBJECTAGG (clauses, ORDER BY, scope ordering, OVER), batch-level 13600/13620. Done 2026-10-04 (tail5, `harness/corpus/json4/`, docs/reference/json.md "The json data type"): the json data type (canonical-text values, UTF-8 varchar(max) BIN2 on the wire, parsing/normalization with 13609 byte positions, 1007, 13645, conversions 13639/13640/257/206/529, non-comparability 13636/421/5335/402/8117, catalog and describe, columns, variables, parameters, ALTER COLUMN), JSON functions over json values with their error states, RETURNING JSON on constructors and aggregates, the 8120 qualifier `dbo.t.g` (fork B1). Added 2026-10-06: native binary DATALENGTH and variable/UPDATE/MERGE `.modify()`; see the native JSON storage audit below for remaining edge cases. Missing: CLR arguments (13666; hierarchyid/geometry/geography/vector are 50100 since 2026-10-04; `geometry::Point()` does not parse), rows of earlier groups before a JSON_OBJECTAGG 13638 under ORDER BY (json-aggregates#017), JSON_MODIFY result collation from a value's explicit collation
- [~] Scalar built-ins (`bind/fn_*.mbt`, `exec/fn_*.mbt`, corpus `harness/corpus/functions`, 987 captured cases, 968 pass): date/time (DATEADD, DATEDIFF(_BIG), DATEPART, DATENAME, YEAR/MONTH/DAY, EOMONTH, *FROMPARTS, TODATETIMEOFFSET, SWITCHOFFSET, ISDATE, DATETRUNC), string (STUFF, PATINDEX, CONCAT_WS, STR, QUOTENAME, STRING_ESCAPE, TRANSLATE, SOUNDEX, DIFFERENCE, FORMAT (.NET number/date/TimeSpan formats in 67 generated cultures, 2026-10-04), collation-aware TRIM/REPLACE/CHARINDEX, folded result lengths), math (ROUND, POWER, trig, LOG, DEGREES/RADIANS, RAND = SQL Server's generator), CHOOSE, GREATEST/LEAST, ISNUMERIC, HASHBYTES, CHECKSUM/BINARY_CHECKSUM (every type but decimal/sql_variant; strings under BIN/BIN2 and SQL_Latin1_General_CP1_CI_AS/CS_AS), COMPRESS/DECOMPRESS, ROWCOUNT_BIG, CURSOR_STATUS, COLUMNS_UPDATED (2026-10-04, corpus `conversion/`). DATE_BUCKET and PARSE/TRY_PARSE done 2026-10-03 (analytic corpus). Missing: FORMAT/PARSE dates in Um Al-Qura (ar-SA) and cultures outside the generated table (50173/50171), SIN/COS/TAN/EXP/LOG last-digit differences (SQL Server uses the Windows CRT; ~2-10% of inputs differ by 1 ulp), CHECKSUM of decimal/sql_variant/Windows-collation strings, HOST_NAME/SUSER_SNAME/USER_NAME, NEWSEQUENTIALID in defaults (302 elsewhere is done)
- [x] Functions round 2 (2026-10-04, corpus `functions2/` 292 cases, docs/reference/format-parse.md, result-metadata.md): FORMAT/PARSE cultures from a generated .NET culture table (harness/gen/cultures.mjs; name validation, invariant fallback for unknown languages, session-language default), .NET custom/standard numeric formats, DateTime/TimeSpan formats; GREATEST/LEAST typing, nullability and max lengths; CONCAT/CONCAT_WS argument checks and binary as UTF-16; ORDER BY constant keys (ORDER token, 408, 1008, 209); window output order; IGNORE NULLS for LAG/LEAD/FIRST_VALUE/LAST_VALUE; SWITCHOFFSET numeric zones; float literal 337/168 and string→float whitespace; STDEV/VAR one-pass formula; sys.dm_exec_describe_first_result_set and sp_describe_first_result_set. Open: decimal-zero permille quirk (`FORMAT(0.00, '0.0‰')` is `00.0‰`), tie order of sorts and PARTITION-only window aggregates (plan-dependent), clustered-index scan order without ORDER BY (store), CHECKSUM of decimals/Windows-collation strings, sp_prepare in batches
- [~] sql_variant (2026-10-03, corpus `variant/`, `properties/`, docs/reference/sql-variant.md): type, values with base type, SSVARIANT wire (COLMETADATA 8009, every base type, RPC decode), CAST/CONVERT/TRY_CAST both ways (529 state 3 out of a variant, 206/257 on assignment), family-ordered comparison (ORDER BY, GROUP BY, DISTINCT, MIN/MAX), DATALENGTH, operator errors (257/402/8117/8116), per-function argument rules (8116/257 table), FOR JSON, multi-row VALUES type unification, simple parameterization of string/binary literals for INSERT/UPDATE of permanent tables; SQL_VARIANT_PROPERTY, SERVERPROPERTY, DATABASEPROPERTYEX, CONNECTIONPROPERTY, SESSIONPROPERTY. Missing: CHECKSUM/BINARY_CHECKSUM of a variant (50100), CONNECTIONPROPERTY addresses (50100), sql_variant RPC parameters with non-default collations (50100), whole-batch compile errors for variant type errors other than PRINT/RAISERROR of a variable (later statements' errors come after earlier statements ran), COLLATE on a variant reports 447 state 1 (SQL Server: 0)
- [x] Long tail round 4 (2026-10-04, corpus 20,088 → see decisions.md; captures `harness/corpus/tail/*`): view / inline-function columns read as base columns (flags 8/9) unless computed; `WHERE 1=0` between integer literals removes the source; WHERE conjuncts over the left input of CROSS/OUTER APPLY filter it first; END CATCH sets @@ROWCOUNT 0; COUNT(NULL) 8117 before 157; batch-level compile errors for table hints (321/1047/10746/367/8171/307/308/8622), TOP counts (127/1060/1014/1031; run-time ones end the batch), window functions (4114, 10755, 10753), MERGE WHEN clauses (10714/5324), undeclared table variables (1087); table variables visible only in their own module; UPDATE/DELETE FROM outer joins skip NULL-extended targets and accept APPLY; BACKUP of a missing database (911 + 3013), 155 for unknown BACKUP options, RESTORE 50100; SET ANSI_NULLS OFF (two-valued `= NULL`, per-module CREATE-time setting, uses_ansi_nulls), the other SET options reported by SESSIONPROPERTY/@@OPTIONS with their unmodelled effects as 50100, FROM exposed-name errors 1011/1012/1013, 4413, sp_refreshview, sp_set_session_context validation; STRING_ESCAPE/STRING_SPLIT/QUOTENAME/HASHBYTES argument rules, CHECKSUM of decimals and version-0 Unicode text, compile-time DECLARE, CREATE FUNCTION compile checks and schema-binding dependencies (3729/4512/4513), SOUNDEX code page rules, CONVERT of date/time types to binary. Open: uncorrelated aggregate subqueries evaluated over zero outer rows (8153, aggregate-warning-boundaries#008), rows of earlier groups before an aggregate error (json-aggregates#017). Closed in tail5 (2026-10-04): named `WINDOW` clause, `NEXT VALUE FOR … OVER`, several syntax errors from one statement (fork B1); READPAST 650, INDEX hints on views (fork B2)
- [x] Long tail round 5 (2026-10-04, branch `tail5`, corpus 20,453/20,587 → 20,507/20,604; captures `harness/corpus/json4/*`, `tail5/*`): the json data type and RETURNING JSON (see the JSON item); named WINDOW clause, NEXT VALUE FOR … OVER, yacc-style syntax error recovery (several 102/156/319 per batch, `parse/recovery.mbt`; parse-diff compares every error), 8120 names as written in FROM, 209 for ambiguous grouped names (fork B1); READPAST 650/4102, table hint shapes (4430, 1069, 207+215, 1018), ALTER SCHEMA TRANSFER, sticky lob_data_space_id, sp_prepare of non-SELECT statements (fork B2); linguistic string comparison ~10x faster (ASCII streaming + shared-prefix skip, fork A); process isolation runs each case in its own database. Open: `FROM missing (a, b)` 208 and `t (@x)` 137 (50100), view binding line 13 for 208, the two 4104 of collation-join-scopes#006/#007, non-ASCII sort keys still slow (fixed 2026-10-05: sort keys)
- [x] TOP / OFFSET / FETCH beyond int (2026-10-05, compat report 0.1.3 findings 2–3; corpus `query/top-fetch-bigint`, `conversion/decimal-numeric-name`): integer literals above 2147483647 (numeric(p,0)) and other numeric(p,0) *constants* are valid row counts (decimal(p,0), and numeric variables, are 1060); values beyond bigint are run-time 8115; run-time OFFSET/FETCH counts are bigint (were truncated to int: large FETCH returned no rows); constant OFFSET/FETCH checks are batch-level (10743/10742, 1060/10744), run-time NULL/negative are 10743/10742/1014/127 class 15. Arithmetic over numeric and decimal is named numeric (an integer literal takes the other operand's name); CASE/UNION/COALESCE take the first operand's name. Open: `TOP (SELECT …)` subquery counts are a parse error (156) in bitsql; INSERT TOP stays 50100
- [~] Untyped NULL through derived tables (2026-10-04, external compatibility report; corpus `query/derived-untyped-null`, `query/union-untyped-null-tvf`): a derived table / CTE / VALUES / DISTINCT / TOP / GROUP BY / join / set-operation column that is only the NULL constant (also `NULL + NULL`, `ISNULL(NULL, NULL)`, `-NULL`, `~NULL`) reports int but binds as the untyped NULL (INSERT/UPDATE/MERGE into datetimeoffset/uniqueidentifier/xml, UNION takes the other branch's type, `s.o = N'abc'` compares as nvarchar); views, inline TVFs, SELECT INTO, `(SELECT NULL)`, `CAST(NULL AS int)`, mixed VALUES and `-col` stay int (206). Also 4127 for COALESCE of NULL constants, 8133 for IIF, 8117/8116 for MIN/MAX/COUNT/SUM/STRING_AGG over a NULL constant, `NULL * 2` typed int (was untyped after folding), UNION of a NULL branch with date (was 257). Open: a constant CASE/COALESCE/IIF folding to a bare derived NULL column keeps flags 1 in SQL Server, bitsql reports 33 (`query/derived-untyped-null-folded` fails on purpose); INTERSECT result nullability with a NULL-constant operand (`SELECT CAST(NULL AS nvarchar(3)) INTERSECT SELECT N'abc'` is flags 0 in SQL Server, bitsql 33/1); `CAST(NULL AS int) UNION ALL SELECT N'abc'` sends one row before 245 (SQL Server none)
- [x] Long literals (2026-10-05, 0.1.3 compat report finding 1; corpus `compat/long-literal-unify`): an `N''` literal over 4000 characters, a `''` literal over 8000 bytes and a `0x` literal over 8000 bytes are typed (n)varchar(max) / varbinary(max), so multi-row VALUES, UNION, CASE and INSERT VALUES/SELECT unifying them with a short literal keep the whole value (stored 4000 of 4060 characters before). varchar(5000)-style sized operands meeting nvarchar still cap at 4000 (captured). Noticed, not fixed: `ORDER BY LEN(v)` next to `CAST(LEN(v) AS int)` over a non-max column matches the select item in SQL Server (ORDER [n], flags 33) because the cast is a no-op; bitsql adds a hidden key (flags 1)
- Gate: all non-concurrency tests on the emulator.

- [~] Sequences (session/sequence.mbt, corpus `sequence/`): CREATE/ALTER (RESTART [WITH], INCREMENT, MIN/MAX, CYCLE, CACHE)/DROP SEQUENCE, NEXT VALUE FOR in SELECT, VALUES, DEFAULT constraints and variables; values not transactional; 11702/11703/11719/11721/11728 (batch abort)/11729/15151/2714/3701; flags 0. sys.sequences. 2026-10-04 (tail5 fork B1, `tail5/b1-next-value-over`): NEXT VALUE FOR … OVER (ORDER BY) with its 117xx errors. Missing: one value per row for repeated references of a sequence (raises 50100), sp_sequence_get_range, decimal precision > 18

- [x] Identity/permission functions for the single `sa` login (USER_NAME, USER_ID, SUSER_NAME/SNAME/ID/SID, CURRENT_USER, SESSION_USER, USER, SYSTEM_USER, ORIGINAL_LOGIN, APP_NAME and HOST_NAME from LOGIN7, IS_SRVROLEMEMBER, IS_MEMBER, IS_ROLEMEMBER, HAS_DBACCESS, DATABASE_PRINCIPAL_ID, PERMISSIONS()), CONTEXT_INFO / SET CONTEXT_INFO, sp_set_session_context / SESSION_CONTEXT (read-only keys → 15664), sp_helpindex (corpus `misc/`, `sysprocs/`)
- [x] SET statements (session/set_options.mbt, corpus `set/`): captured CurCmds per option; NOCOUNT, XACT_ABORT, DATEFIRST (DATEPART week/weekday, DATETRUNC week, @@DATEFIRST), LOCK_TIMEOUT (@@LOCK_TIMEOUT), DEADLOCK_PRIORITY (victim choice), CONTEXT_INFO, isolation level take effect; @@OPTIONS reflects NOCOUNT/XACT_ABORT. 2026-10-04: ANSI_NULLS OFF is emulated (docs/reference/database-settings.md "Session SET options"); QUOTED_IDENTIFIER/ANSI_PADDING/CONCAT_NULL_YIELDS_NULL OFF and NUMERIC_ROUNDABORT ON are accepted and reported, and the constructs whose result they change raise 50100. Other non-default values bitsql does not model raise 50100 instead of being ignored: ANSI_WARNINGS/ANSI_NULL_DFLT_ON OFF, IMPLICIT_TRANSACTIONS/NUMERIC_ROUNDABORT/CURSOR_CLOSE_ON_COMMIT/NOEXEC/FMTONLY/PARSEONLY/SHOWPLAN_*/STATISTICS ON, ROWCOUNT ≠ 0, TEXTSIZE other than the maximum, DATEFORMAT other than mdy, LANGUAGE other than us_english
- [x] RESETCONNECTION (tedious `connection.reset()`): rollback + ENVCHANGE RESETACK, temp tables, cursors, SET options, context info and session app locks reset (captured; harness test/reset.test.mjs)
- [x] DMVs sys.dm_exec_sessions / dm_exec_requests / dm_exec_connections over live sessions (corpus `dmv/`): isolation, SET state, open transactions, suspended requests with LCK_M_* wait type and blocking session. Only user sessions are listed (no system sessions)
## Phase 6: concurrency

- [x] Transactions over persistent roots (BEGIN/COMMIT/ROLLBACK, ENVCHANGE 8/9/10, statement-level rollback). Concurrent writers merge: COMMIT re-applies the transaction's row/object changes onto the newest committed state (`Db::rebase`), and READ COMMITTED statements refresh their view the same way. 50107 remains only for a conflicting change that no lock prevented (e.g. DDL racing DML)
- [~] Lock manager wired (decisions.md: request restart): X on modified/inserted keys, UPDLOCK/HOLDLOCK/SERIALIZABLE/XLOCK reads lock the PK point or whole table, statement vs transaction durations, release on commit/rollback/statement end; parked requests re-run in the same handle call. Unhinted reads take S (statement duration under READ COMMITTED, transaction under REPEATABLE READ/SERIALIZABLE; none under NOLOCK/READ UNCOMMITTED/SNAPSHOT), including subqueries in WHERE/IF/WHILE. SET LOCK_TIMEOUT (0 immediate, n via host timers) → 1222 + 3621, statement-level. Corpus `locking/` (8 multi-connection captures). Missing: key-range locks for SERIALIZABLE beyond PK points/whole table, secondary-index seeks (reads lock the whole table unless the WHERE pins the PK), FK S-locks, SNAPSHOT update conflicts (3960), NOLOCK/READ UNCOMMITTED dirty reads. 2026-10-05: grants indexed per (table, session) with bulk release and one-allocation row keys (decisions.md). Missing: lock escalation (captured: OBJECT X once a statement holds ~6250 key + page locks on one table; bitsql never escalates, so a concurrent writer to an untouched row of a table with a large uncommitted DML is not blocked; `ALTER TABLE SET (LOCK_ESCALATION)` is ignored) READ_COMMITTED_SNAPSHOT done 2026-10-04 (no read locks, see Databases)
- [x] Deadlocks: wait-for cycle detection; on equal cost the session waiting longest is the victim (captured), gets 1205 (state 51, class 13) then ENVCHANGE rollback and DONE 253; DEADLOCK_PRIORITY not implemented
- [x] Application locks: sp_getapplock / sp_releaseapplock (Session and Transaction owners, all five modes, @LockTimeout incl. 0 → -1 and waits → 1, reference counts), APPLOCK_MODE, APPLOCK_TEST; the procedures' internal DONEINPROC sequences reproduced per path (corpus `applock/`, incl. Prisma Migrate's call). 2026-10-04 (msduck gaps-applock 99/100, corpus `stmts/applock-validation`): invalid/NULL @LockMode/@LockOwner (15625), xp_userlock errors 1227/1224/1230/1202/3918/1223 in captured order, DEFAULT and named-argument checks, per-principal lock spaces, 255-character resources, combined modes (SIX, UIX), APPLOCK_MODE/APPLOCK_TEST run-time and compile-time errors. Deadlock victim returns -3 (unverified); gaps-applock #068 needs sys.dm_exec_describe_first_result_set
- [x] WAITFOR DELAY/TIME: the request parks with a host timer; its re-run passes completed waits (CurCmd 243, captured). ATTENTION cancels it. 2026-10-04: argument grammar and types (see TRY/CATCH item); a negative int delay is 50100 (SQL Server waits past the client timeout)
- [x] Deterministic mode + replay (event log; scheduling is deterministic by construction)
- [x] `emulator.snapshot` / `emulator.restore` (all databases, identity counters, @@DBTS, procs; O(1) via immutable Db values)
- [x] BACKUP DATABASE / RESTORE DATABASE|HEADERONLY|FILELISTONLY|VERIFYONLY as an in-memory backup store keyed by device path (2026-10-04, corpus `backup/`, decisions.md): FORMAT/INIT/NOINIT sets, MOVE, REPLACE, FILE, STATS, captured messages and errors (3201, 3021, 3147, 3154, 3159, 3234, 1834/3156/3119, 3287, 4038, 3101, 3102), msdb backupset/backupmediaset/backupmediafamily/backupfile/restorehistory/restorefile. Missing: BACKUP LOG (FULL), DIFFERENTIAL, NORECOVERY chains, real .bak files
- Gate: the MSSQL CI job is removed; nightly cross-check remains.

## Databases

- [x] Multiple databases: CREATE/DROP DATABASE (203/204, 1801, 3701), USE (911), login to unknown database → 4060 + 18456 (msduck capture); host `--database NAME`, `--auto-create-databases`
- [x] Server-wide database discovery and cross-database names (2026-10-04, corpus `database/cross-database*`, decisions.md): sys.databases / `master.sys.databases` / DB_ID / DB_NAME list every database from any database (ids per server); `db.schema.t` reads and DML, transactions spanning databases (also through USE), CREATE/ALTER/DROP TABLE, CREATE INDEX, TRUNCATE, SELECT INTO in another database; `db.sys.x` / `db.INFORMATION_SCHEMA.x`, OBJECT_ID / OBJECT_NAME(id, db_id) / IDENT_* / COL_LENGTH of another database; 166 for CREATE VIEW/PROCEDURE with a database prefix; 2702. Missing (50100, corpus `database/cross-database-unsupported` fails on purpose): views, functions, synonyms, sequences of another database, DML on its tables with triggers or with defaults/computed columns/CHECKs calling functions or sequences, other DDL on its objects; sp_help & co. for other databases; procedures are still stored server-wide by name; 166 for CREATE FUNCTION/TRIGGER prefixes (SQL Server adds a 178 for the function); user database ids are the lowest free id (unverified)
- [~] Database and session settings (2026-10-04, corpus `settings/`, docs/reference/database-settings.md): ALTER DATABASE (CurCmd 215; 448/15048/12104/102 at compile time, 5011+5069, 226) with COLLATE (database default collation for literals, variables, parameters, new columns, catalog views, savepoints, case-sensitive table names; USE sends the collation ENVCHANGE, CurCmd 226), COMPATIBILITY_LEVEL, READ_COMMITTED_SNAPSHOT (no read locks, last committed state), ALLOW_SNAPSHOT_ISOLATION (3952 otherwise), CURSOR_DEFAULT, SINGLE/RESTRICTED/MULTI_USER, READ_ONLY (3906) / READ_WRITE, RECOVERY, ANSI option defaults; CREATE DATABASE COLLATE; sys.databases and DATABASEPROPERTYEX follow; DBCC USEROPTIONS; SET DATEFORMAT (six orders, both parsers) and SET LANGUAGE (34 languages from sys.syslanguages: month/day names, date order, DATEFIRST, localized INFO 5703, sys.syslanguages, @@LANGID); UTF-8 collations (`_SC_UTF8`, `_BIN2_UTF8`: byte lengths, wire UTF-8, COLLATE code page conversion), `_SC` LEN/LEFT/RIGHT/SUBSTRING/REVERSE, UPPER/LOWER tables per collation version. Missing: localized error messages, behaviour of compatibility levels below 170, CURSOR_DEFAULT LOCAL effect on DECLARE CURSOR, RECURSIVE_TRIGGERS ON / PARAMETERIZATION FORCED (50100), MODIFY NAME / files (50100), NOLOCK dirty reads, column names under CS database collations, CHECKSUM of UTF-8 varchar

## ORM and query-builder compatibility

`harness/orm` (`cd harness/orm && npm test`, not in `scripts/check.sh`):
the same workload on the oracle and on bitsql, compared step by step
(data, error numbers/messages, logged SQL). 2026-10-04: knex 73/73,
Sequelize 67/67, TypeORM 44/46 (2 known), Prisma 40/40 steps match.

- [x] knex 3.3.0 (tedious): migrations + lock tables, schema builder (every column type, comments via extended properties, indexes, FKs, alterTable incl. rename/drop column, views, createTableLike), CRUD with `returning`, batch inserts, joins/aggregates/CTE/union, raw, transactions with savepoints and isolation levels, row-lock hints
- [x] Sequelize 6.37.8 (tedious): sync force/alter, describeTable/showIndex/showAllSchemas/FK queries, associations with include, paranoid/timestamps, findAndCountAll, upsert (MERGE), bulkCreate, managed/unmanaged transactions with isolation levels and savepoints
- [x] TypeORM 1.1.1 (mssql): migration generation (schema diff) and runs, synchronize, query builder, repositories with relations, pessimistic/optimistic locks, query runner DDL and introspection
- [x] Prisma 7.10.0: CLI schema engine (tiberius) `migrate deploy`/`status`/`diff`, `db push`, `db pull`; client via `@prisma/adapter-mssql` (CRUD, nested writes, relation filters, batch and interactive transactions, raw)
- [x] Fixed on the way (corpus `orm/`): extended properties (sp_add/update/dropextendedproperty, sys.extended_properties, sys.fn_listextendedproperty), ODBCSCALE, DOUBLE PRECISION, qualified INSERT column lists, `db..t` names, RPC 4002/8016 decode errors instead of a dropped connection, NULL assignment to date/time/guid columns (was 529), compile-time 206/257 for typed stores, view-computed column flags through derived tables, ALTER COLUMN under a DEFAULT, OBJECT_DEFINITION(0), USE inside dynamic SQL, DISTINCT output order
- [x] Computed columns referencing columns declared after them (2026-10-04, external compatibility report, corpus `catalog/computed-forward-refs`): CREATE TABLE, table variables and ALTER TABLE ADD bind computed columns against all columns; 1759 for forward/self references to computed columns; 2715 column ordinals; batch-level 8183 for CHECK/REFERENCES/NULL/NOT NULL on non-persisted computed columns
- [x] External compatibility report round 2 (2026-10-04): untyped `DEFAULT (NULL)` applies to every column type (date, time, guid, xml…) on every default path, typed defaults are checked like an assignment at CREATE (206/257; corpus `constraints/default-untyped-null`, `default-type-check`); a column definition's `FOREIGN KEY (col) REFERENCES …` binds its listed column (8140 for more than one), column CHECKs naming another column are 8141 + 1750, two column CHECKs 8148 (`constraints/inline-fk-columns`, `column-check-other-column`); PERSISTED determinism (4936) covers character↔date conversions without a deterministic style (also implicit and inside date functions), sql_variant sources, metadata/security/session functions, `@@` globals, FORMAT/DATENAME/ISDATE/PARSE/AT TIME ZONE, DATEPART week/weekday (`constraints/persisted-determinism`, 210 cases).
- [x] Compat report 0.1.3 #4 (2026-10-05, corpus `query/cte-assignment-select`, `query/unused-cte`): `WITH … SELECT @v = …` binds its CTEs (one, several, recursive; standalone, procedures, triggers; last row in ORDER BY order wins, no rows leaves the variable); FOR XML/JSON on an assignment SELECT is batch error 6819 (state 3, message says FOR XML for both); a WITH whose SELECT is a bare constant projection (no FROM/WHERE/TOP/DISTINCT/ORDER BY/subquery/aggregate) is batch error 422 on the SELECT's line. Missing: 422 for projections with non-aggregate function calls (not captured, left running)
- [x] Legacy datetime arithmetic and CURRENT_DATE (2026-10-04, corpus `conversion/datetime-arithmetic`): `datetime`/`smalldatetime` ± numbers, bit, character data and each other (day counts in 1/300 s units, 8115 out of range); `*` `/` 257, `%` and newer date/time types 402; 206 names the temporal type first. Defaults are stored like assignments (2628 for an over-long string default; msduck unicode-storage *-overflow-default).
- [x] msduck re-import 2026-10-04 (13 changed/new capture files: gaps-*, translate/concat/float grids, apply-full-join, plus new adapters `openjson-isnull`, `default-collation`; `gaps-unicode-predicates` now follows the fixture's collation, recaptured by msduck under the server default): ignorable code units and accent order of the version-0/100 sort tables dumped from SQL Server (`harness/src/dump-collation-weights.mjs`); ORDER BY on char/varchar under SQL_ collations uses the SQL sort order; OPENJSON `value` is coercible-default; CASE/COALESCE take the precedence-winning collation and fold constant branches for max types too; `ISNULL(a, b)` is nullable when b may be cut to a's length; `Latin1_General_140_*` is 448; column COLLATE errors (448 state 2 for the batch, 447 on non-character types); type errors in DEFAULTs are raised at CREATE (`ISNULL(int, SESSION_CONTEXT(..))` 257). Not done: `cross-database` (fixed database names in master of a fresh container), bulk-character-* (BulkLoad), attention/TVP/login files (not corpus-shaped).
- [x] Compile-time type errors for the whole batch (2026-10-04, `session/prebind.mbt`, corpus `conversion/datetime-arithmetic`, msduck try-binding-error, gaps-computed session-variant-writes): a batch without DDL/EXEC/USE/SELECT INTO/table variables/binding-relevant SET options is bound up front in compile-only mode; 206/257/402/8116/8117 (with the binder's earlier deferred errors) fail it before anything runs, also inside IF/TRY; a missing object stays deferred. Batches with DDL still bind per statement (open: SQL Server compiles their statements over existing objects up front too).
- [ ] Binary to datetime/smalldatetime values (`@d - 0x01`): 50101 (`conversion/binary-to-date`).
- [ ] Binary to date/time/datetime2/datetimeoffset values (explicit conversion allowed; SQL Server reads an internal image, 0x5B950A AS date is 1900-01-01): 50100 (`conversion/binary-to-date`).
- [ ] ALTER TABLE ADD … CHECK naming an unknown column is a compile-time 207 for the whole batch on SQL Server; the emulator raises it when the statement runs.
- [ ] Non-persisted computed columns are evaluated on INSERT (SQL Server evaluates them when read: `c varchar DEFAULT 'x', a AS CAST(c AS int)` inserts fine and the SELECT fails with 245); several binding errors from one CREATE TABLE (SQL Server reports a computed column's 207 and a CHECK's 207 together, bitsql the first) — both probed 2026-10-04, no corpus case yet
- [ ] Object ids per database (SQL Server numbers every database from 1221579390; bitsql's counter is server-wide because identity counters, compiled UDFs and key-range locks are keyed by object id alone): corpus `orm/object-ids` fails on purpose
- [ ] Identity property of view columns (sys.columns.is_identity, COLUMNPROPERTY IsIdentity, sys.identity_columns with NULL seed, IDENT_SEED of a view): corpus `orm/view-identity-columns` fails on purpose
- [x] TLS (2026-10-04): PRELOGIN encryption as captured (OFF → login-only TLS, ON/REQ → full TLS, NOT_SUP → plaintext), handshake in PRELOGIN packets, TLS 1.2 cap, built-in self-signed certificate (`--tls-cert`/`--tls-key`, `--no-tls`), `dm_exec_connections.encrypt_option`. tedious/mssql defaults (`encrypt: true`) and Prisma `encrypt=true|false` connect unchanged; harness and ORM suite now use `encrypt: true` on both targets. TDS 8 (`encrypt: strict`) not supported (the oracle image refuses it too)
- [ ] Extended properties beyond SCHEMA / TABLE|VIEW|PROCEDURE|FUNCTION / COLUMN (database level, INDEX, CONSTRAINT, PARAMETER, TRIGGER, TYPE …: 50100), and fn_listextendedproperty with non-constant arguments (50100)
- [ ] Plan-dependent row order of DISTINCT with OR-ed seeks (TypeORM `known.json`)

## Phase 7: packaging

- [x] Native release binary 2.7 MB (libc only); `Dockerfile` on distroless/cc: **26.4 MB image, ~0.8 MB RSS idle** (2026-10-03; 10k-row table ≈ 8 MB RSS). Possible next: static musl build on scratch (~3 MB image)
  - 2026-10-03 (later): binary 5.3 MB, ~4.9 MB RSS idle after time-zone data, catalog seeds, cp1252 best-fit tables
  - 2026-10-04: binary 11.3 MB (10.9 MB before TLS), image 35 MB, ~4.6 MiB RSS after TLS logins; distroless/cc already ships libssl3, which `moonbitlang/async/tls` dlopens
- [x] `mirek/bitsql:0.1.0` (`0.1`, `latest`) pushed to Docker Hub 2026-10-04, amd64 only (with TLS)
- [x] arm64: `mirek/bitsql:0.1.1` (`0.1`, `latest`) is a linux/amd64 + linux/arm64 manifest list, built by `scripts/docker-publish.sh` (cross gcc in a bookworm container; arm64 smoke-tested under qemu-user: by default a 37 s quick smoke of corpus/smoke + float, analytic and conversion cases; `FULL_ARM64_SMOKE=1` for the whole suite, about 1 h; C built with `-ffp-contract=off`) 2026-10-04
- [x] `mirek/bitsql:0.1.2` (`0.1`, `latest`) pushed 2026-10-05, amd64 + arm64 (amd64 full suite 20685 pass; arm64 quick smoke 570/570)
- [x] `mirek/bitsql:0.1.3`: `@@VERSION` and `host --version` name the release; the third compatibility report (tested 0.1.1 arm64) reproduced 71/71 identical to SQL Server on 0.1.2 amd64 and arm64 (untyped NULL defaults × 8 types × 4 forms × 2 insert paths, named inline FK with column list, persisted string→date 4936 and counterexamples)
- [ ] Local `moon build` on arm64 hosts (Apple silicon, arm64 Linux) still lets the C compiler fuse multiply-add, so float results can differ from SQL Server; `cc-flags` in moon.pkg would fix it but replaces moon's default flags (drops -O2/debug flags)
- [x] Public visibility on Docker Hub (anonymous manifest pull returns 200, checked 2026-10-05)
- [x] Container benchmark vs real SQL Server (`npm run bench:compare`, README refreshed for 0.1.9 on 2026-10-05): 24 shapes 257 ms vs SQL Server 702 ms; accented-text sorting 3.11 vs 3.30 ms; 12.5 MiB download vs 604.5 MiB, cold start 128 ms vs 2.69 s, 4.4 MiB idle vs 1.17 GiB. Seven individual shapes remain slower.
- [x] `mirek/bitsql:0.1.8` (`0.1`, `latest`) published 2026-10-05 for amd64 + arm64: compact single-column grouping slots; full gate 269 MoonBit tests and 20702 client/corpus passes (3 skips), amd64 release smoke 20702 passes, arm64 smoke 571/571. Registry manifests verified for all three tags.
- [x] `mirek/bitsql:0.1.9` (`0.1`, `latest`) published 2026-10-05 for amd64 + arm64: early linguistic-primary decisions, compiled CHAR/NCHAR and immutable character results. Full gate against the exact amd64 release binary: 271 MoonBit tests, 20702 client/corpus passes (3 skips); arm64 smoke 571/571.
- [~] 0.1.10 release prepared 2026-10-06 for amd64 + arm64: integer set membership. Full gate against the exact amd64 release binary: 272 MoonBit tests, 20702 client/corpus passes (3 skips); arm64 smoke 571/571. Container comparison: 24 shapes 257 vs 696 ms, INTERSECT 2.55 vs 4.16 ms. README refreshed. Registry publication awaits explicit destination/tag authorization after automatic approval review rejected the push.
- [~] Executor speed vs SQL Server on set-heavy shapes at 20k rows (same benchmark), as of 0.1.3: GROUP BY/DISTINCT/UNION/ORDER BY/ROW_NUMBER 3–9× slower, UPDATE all rows/UPDATE FROM 4–5× slower, accented-text ORDER BY 35× slower; parameterized point SELECT through sp_executesql 0.16 vs 0.15 ms. 2026-10-05 (decisions.md "sort keys, hash grouping, set-at-once DML"): sort keys, hash grouping, stable merge sort, UPDATE/DELETE/MERGE applied once with unchanged-index replacement and O(n) bulk deletes; bulk multi-row INSERT, hashed EXCEPT/INTERSECT; 1.5–4× faster across the shapes (24 shapes 1.08 → 0.50 s). 2026-10-05 performance push (docs/design/performance.md, papers in performance.bib): closure-compiled expressions, streamed scalar aggregates and joins, accumulator GROUP BY, Int64 hash tables for joins/grouping/unnesting, unnested integer-key correlated subqueries, normalized ORDER BY keys, TOP-N heap, packed collation elements, scan cache, cheaper UPDATE/FK/lock paths; 24 shapes 478 → 251 ms (best of 3). Missing: IN sets by hashing, correlated subqueries on non-integer keys, per-row validity checks of memoized uncorrelated subqueries (~1 ms/20k rows), per-request overhead (binding runs twice per batch: prebind + run; 2026-10-05: parse cache, precheck memo, the first query reuses the prebind plan, seekable DML WHERE; point SELECT server CPU 62 → 40 µs; open: a cross-request plan cache needs a catalog generation counter, decisions.md) 0.1.4 (README): 24 shapes 511 ms vs SQL Server 695 ms (0.1.3: 1.09 s), 40k-row load on par (49.8 vs 50.1 ms); still slower per query on sorting/grouping (2–3×), correlated subqueries (3.7–5.2×), accented-text ORDER BY (8×), UPDATE all rows/FROM (1.4×)

Performance follow-up (2026-10-05): single-column exact collation/temporal
keys now group through unboxed representative-position slots. At 20k rows,
interleaved release-binary checks improved string grouping/distinct/union
by 3–9% and an all-unique-string DISTINCT check by 13%; equivalence tests
cover collation comparisons, temporal key equivalence, NULLs and group
numbering. See `performance.md` for measurements and the rejected raw-string
cache experiment. Beating SQL Server on every benchmark remains open.

The 0.1.9 performance follow-up adds early decisions from unequal leading
linguistic primary weights and compiled CHAR/NCHAR calls with immutable
single-character results. Reference-equivalence tests and isolated/combined
measurements are in `performance.md`; the remaining benchmark gaps continue
to guide work.

The 0.1.10 performance follow-up specializes integer EXCEPT/INTERSECT
membership while retaining conversion-aware comparison for other probes;
equivalence tests and before/after timings are in `performance.md`.

- [x] Reduce ROW_NUMBER partition-allocation overhead while preserving the
  existing sort, boundary comparisons, and output order: direct scan measured
  7–8% lower mean time on 2026-10-06; equivalence tests and targeted captures
  checked; full gate passed (273 MoonBit tests, 20702 client/corpus passes,
  3 skips). Included in published 0.1.13 (`performance.md`).

- [x] 0.1.11 preparation: streaming exact grouping keys and an allocation-free
  hash improve text grouping/distinct/UNION, including the all-unique check;
  combines the tested ROW_NUMBER scan. Exact amd64 binary passed the full
  gate (273 MoonBit tests, 20702 client/corpus passes, 3 skips); arm64 smoke
  passed 571/571. Container benchmark: sum of 24 five-sample medians 256 vs
  641 ms (2.5×); UNION near parity, text grouping/window/subquery gaps remain.
  README refreshed; raw timings retained. These optimizations shipped
  cumulatively in 0.1.13 after registry authorization.

- [x] 0.1.12 prepared: integer IN/NOT IN hash membership with unchanged
  conversion-aware fallback, NULL semantics, and memo invalidation. Executor
  equivalence tests pass; isolated repeated IN time improves about 27%, NOT IN
  about 11–16%. Exact amd64 release gate: 274 MoonBit tests, 20702 client
  passes, 3 skips; arm64 571/571. Container IN 3.11 vs 4.88 ms, NOT IN 2.39
  vs 3.12 ms, 24 shapes 247 vs 669 ms. README refreshed; shipped cumulatively
  in 0.1.13 after registry authorization (`performance.md`).

- [x] Canonical database-key lookup avoids redundant lowercase conversion
  in db_of/tx_part. Session tests pass (36); isolated timings show small
  uncorrelated-query gains. Context-scoped stamp reader now passes 37 session
  tests, including write/rollback/database/scope transitions. Combined candidate
  improves scalar uncorrelated queries about 16% and NOT IN about 19–20%.
  The first eager cache passed the full gate but regressed write controls;
  lazy state allocation plus a shared DML predicate context now improves
  DELETE WHERE IN about 15–17% while retaining subquery gains. Small overhead
  remains in other write controls. Final 0.1.13 exact amd64 gate passed
  (275 MoonBit tests, 20702 client/corpus passes, 3 skips); arm64 571/571.
  Container total 244 vs 668 ms, scalar uncorrelated 4.26 vs 4.65 ms,
  DELETE WHERE IN 11.2 vs 102 ms. README refreshed. Published 2026-10-06
  as `0.1.13`, `0.1` and `latest`; identical amd64 + arm64 manifests verified
  (`performance.md`).

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

## External compatibility report follow-up (2026-10-06)

- [x] JSON UTC datetimeoffset, zero temporal fractions and binary slash rendering:
  fixed for 0.1.14, with a 50-step oracle regression. Full exact amd64 gate:
  275 MoonBit tests, 20702 existing client/corpus passes (3 skips); new JSON
  allowlist case passed separately on amd64 and arm64. Arm64 standard smoke:
  571/571. Published as `0.1.14`, `0.1` and `latest`; identical amd64 +
  arm64 registry manifests verified.
- [x] Unordered clustered/covering-index scans and MERGE trigger identity order
  investigated and documented as compatibility gaps; retained oracle probes
  outside the passing allowlist. Use ORDER BY for listings and compare audit
  events by business keys. SQL Server 2025 four-row MERGE results differ from
  the report's 2022 observations; do not hard-code the two-row plan.
  See `docs/reference/compatibility-2026-10-05.md`.

## Current performance follow-up

- [x] 0.1.15: reuse normalized ROW_NUMBER partition prefixes (8–10% native gain)
  and adaptively cache repeated text grouping keys (UNION about 18%, ordinary
  text grouping 4–5%, long repeated text about 29%). Unique and low-duplication
  controls stable after rejecting late cache activation; raw-unique SQL-equal
  strings show a small overhead. Full exact amd64 gate passed: 280 MoonBit
  tests, 20703 client/corpus passes, three skips. Arm64 smoke 572/572.
  Container total 243 vs 669 ms; UNION 6.76 vs 7.96 ms, ROW_NUMBER 7.03
  vs 5.97 ms. Published amd64 + arm64 as `0.1.15`, `0.1` and `latest`;
  all three registry manifests verified. Four clear gaps and near-tied EXISTS
  remain; see `performance.md`.

- [x] 0.1.16 published: flat COUNT/COUNT_BIG DISTINCT inputs remove unused
  row/value tuples and representative arrays; shared flat single-column grouping
  improves GROUP BY/DISTINCT/UNION too. Native COUNT DISTINCT improves about 24%;
  unique, nullable, grouped and fallback controls show no regression. Equivalence
  tests include expression traces, errors and NULL warnings. Exact amd64 gate:
  281 MoonBit tests, 20703 client/corpus passes (three skips); arm64 572/572.
  Container COUNT DISTINCT now beats SQL Server, 3.31 vs 3.92 ms. Total shapes:
  234 vs 672 ms. Three clear gaps remain (text GROUP BY, DISTINCT, ROW_NUMBER);
  EXISTS is near parity. Published as `0.1.16`, `0.1` and `latest`; all three
  amd64 + arm64 registry manifests verified (`performance.md`).

- [x] 0.1.17 published: normalize direct ROW_NUMBER column keys without
  per-row key arrays, assemble window output in its final order, and skip exact
  shared normalized-key prefixes during sorting. Combined native ROW_NUMBER
  improves 13–14%; long-prefix sort/window controls improve 5–7%, with other
  controls stable. Exact amd64 gate: 283 MoonBit tests, 20703 client/corpus
  passes (three skips); arm64 572/572. Container ROW_NUMBER 6.01 vs SQL
  Server 5.60 ms, total shapes 235 vs 639 ms. Text GROUP BY, DISTINCT and
  ROW_NUMBER still trail; EXISTS and accented ORDER BY are near parity.
  Published as `0.1.17`, `0.1` and `latest`; all three amd64 + arm64
  registry manifests verified (`performance.md`).

- [x] 0.1.18 published: flat single-column grouping and DISTINCT projection inputs,
  consuming private aggregate output keys, and bounded immutable ROW_NUMBER
  values. Controlled text grouping and DISTINCT improve about 12–15%; unique
  grouping improves about 12%; short ROW_NUMBER partitions improve 5–8%.
  Exact gate: 286 MoonBit tests, 20703 client/corpus passes (three skips),
  arm64 572/572. Text GROUP BY now wins, DISTINCT trails about 5%, ROW_NUMBER
  and EXISTS are near parity. Total shapes: 233 vs 672 ms. Point SELECTs
  trail in this container run; reversed-order native controls do not reproduce
  a regression against 0.1.17. Published as `0.1.18`, `0.1` and `latest`;
  all three amd64 + arm64 registry manifests verified (`performance.md`).

- [x] 0.1.19 published: reuse canonical grouping keys for matching single-column
  DISTINCT sorts; preserve collation/type fallbacks and expression effects.
  Controlled DISTINCT improves 14–15%, unique long text about 31%, with
  unrelated controls roughly stable. Exact gate: 286 MoonBit tests, 20703
  client/corpus passes (three skips), arm64 572/572. Container DISTINCT now
  wins (4.11 vs 4.72 ms); GROUP BY trails about 4%, EXISTS is tied, and
  ROW_NUMBER/point SELECTs are near parity. Exact release-binary controls do
  not reproduce a GROUP BY regression. Total shapes: 234 vs 677 ms.
  Published as `0.1.19`, `0.1` and `latest`; all three amd64 + arm64
  registry manifests verified (`performance.md`).

- [x] 0.1.20 published: compiled EXISTS/scalar subqueries pass their outer row without
  copying Ctx first; empty correlated matches avoid an unused context.
  Controlled EXISTS gains about 23–24%; scalar subqueries also improve.
  Point-SELECT comparison now retains five batches and reports their median.
  Exact gate: 287 MoonBit tests, 20703 client/corpus passes (three skips),
  arm64 572/572. Container EXISTS wins (3.66 vs 4.66 ms); total shapes 229
  vs 645 ms. DISTINCT/ROW_NUMBER trail about 6–7%; text GROUP BY, accented
  sorting and point reads are near parity. All shape and point medians
  verified against raw samples. Published as `0.1.20`, `0.1` and `latest`;
  all three amd64 + arm64 registry manifests verified (`performance.md`).

- [x] 0.1.21 published: compact short ASCII keys under the exact default
  CI collation. Controlled text grouping gains about 19–20%, DISTINCT
  15–16%, COUNT DISTINCT 20–24%, and ROW_NUMBER 26–27%. Full-column
  validation preserves general comparison fallback; adverse interior
  exceptions retain a measured extra-scan cost (`performance.md`). New
  comparator/property tests and oracle case pass. Exact gate: 291 MoonBit
  tests, 20704 client/corpus passes (three skips), ARM64 573/573, live oracle
  2/2. Container text grouping, DISTINCT, COUNT DISTINCT and ROW_NUMBER now
  beat SQL Server. Accented sorting is near parity; container point reads
  are slower, but exact-binary controls do not reproduce a regression.
  All medians verified against raw samples. Published as `0.1.21`, `0.1`
  and `latest`; all three amd64 + arm64 registry manifests verified
  (`performance.md`).

- [x] 0.1.22 published: prepare integer arithmetic bounds and string
  concatenation settings once per compiled expression. Accented TOP-N sort
  gains about 7–12% in final controls; arithmetic expression workloads also
  improve. Other families retain direct fallback calls; small float/money
  control costs remain documented (`performance.md`). Exact gate: 293
  MoonBit tests, 20704 client/corpus passes (three skips), short ARM64
  arithmetic smoke 883/883, live SQL Server 312/312. All 24 container
  query/DML shapes beat SQL Server (227 vs 671 ms total); accented sorting
  wins 2.63 vs 3.28 ms. Point reads still trail 134 vs 123 ms; new per-batch
  CPU measurements correlate spikes with higher server CPU, cause still
  open. Medians verified against raw samples. Published as `0.1.22`, `0.1`
  and `latest`; all three amd64 + arm64 manifests verified (`performance.md`).

- [x] 0.1.23 published: reduce binder allocations without caching bound plans.
  Longer alternating point controls show 4–7% lower median server CPU and
  1–3% lower median latency. Exact gate: 293 MoonBit tests, 20704
  client/corpus passes (three expected skips); short ARM64 smoke and live
  SQL Server controls both 904/904. Fresh container comparison: all 24
  shapes win (226 vs 672 ms total), point reads now narrowly win 117 vs
  123 ms, and all other headline timings win. The current benchmark target
  is met, with earlier intermittent spikes still an unresolved limitation
  (`performance.md`). Published as `0.1.23`, `0.1` and `latest`; all three
  amd64 + arm64 registry manifests verified.

## SQL Server 2025 feature completeness (2026-10-06)

- [ ] Complete the [SQL Server 2025 audit](sql2025-audit.md), covering all user-requested language, type, vector/AI, optimizer, locking and operational additions. Initial oracle-backed `sql2025/` probes pass JSON/CURRENT_DATE and expose seven other differences; these probes are only smoke coverage.

- [x] SQL Server 2025 optional-length SUBSTRING and Base64 encode/decode: oracle-backed `sql2025/substring-optional-length`, `base64`, and `base64-padding` differential cases pass (2026-10-06); result metadata and argument/padding errors captured. Full feature audit remains open.

- [x] SQL Server 2025 bigint DATEADD: widened intermediate arithmetic, range errors, time wrapping and signed-minimum nanosecond behavior; 139 batches in `sql2025/dateadd-bigint*.sql` pass (2026-10-06).

- [x] SQL Server 2025 `||` concatenation: parser, binder and executor, typed conversions, NULL behavior, binary/character metadata, computed columns, collation errors and truncation; four `sql2025/concat-*` differential cases pass (2026-10-06).

- [x] SQL Server 2025 preview configuration: ON/OFF state, transaction rejection/rollback and `sys.database_scoped_configurations` default rows/variant metadata. Three focused differential cases and the full gate pass (2026-10-06).

- [x] SQL Server 2025 fuzzy matching: all four functions implemented with captured metadata, preview/type diagnostics, normalization and algorithms; 256 algorithm pairs pass. Turkish case pairs, combining behavior, complete CP1254 conversion, metadata and supporting string/index consumers now pass 33 newly registered cases; 742 focused fuzzy/collation/UTF-8/search regressions pass. The complete 5,540-name COLLATIONPROPERTY inventory adds 87 cases (120 total additions); its focused run passes 108/108. Full gate passes 1,466 MoonBit and 23,387 client/corpus tests, three existing skips, zero failures (2026-10-07).

- [x] SQL Server 2025 regex: all seven functions and pure byte/character VM implemented; all 477 captured cases pass, including 271 Unicode boundary/fold cases and 126 newly registered raw-group cases. The previous 16 disconnect cases now reproduce, along with native JSON allocation, conversion, mutation and projection contracts. Combined regex/JSON verification passes 2,398 cases; no captured regex failures remain. Full gate passes: 1,466 MoonBit tests and 23,267 client/corpus tests, three pre-existing skips, zero failures; all 477 regex cases ran (2026-10-06).

- [ ] SQL Server 2025 vectors: native float32 values, norms/normalization/properties, and oracle-derived distance kernels implemented. The focused corpus passes 110 registered float32 cases, including cancellation-order and fused-rounding probes; 429 generated core tests use captured results. Declaration diagnostics, preview float16, wider SQL contracts, embeddings and approximate search remain open. See [vector contracts](../reference/vector.md). Full gate passed: 809 MoonBit tests, 21,123 client tests and three pre-existing skips; all 110 registered vector cases ran (2026-10-06).

- [ ] SQL Server 2025 vector completion: preview float16 storage and its distinct distance kernel now pass all 150 captured vector cases, including descriptor recovery, cross-base/type error precedence, preview cache transitions and maximum dimensions. 728 generated vector core tests use oracle outputs. Embeddings, approximate indexes/search and wider SQL contracts remain open; full gate passed: 1,108 MoonBit tests, 21,163 client tests and three pre-existing skips; all 150 vector cases ran (2026-10-06).

- [~] Vector index/search grammar (2026-10-07): explicit AST and argument/option diagnostics implemented; 110 investigative oracle cases now cover index contexts, search contracts and actual graph edges. Real construction/search remains open. The build-query and pruning findings are recorded in [vector contracts](../reference/vector.md); approximate search must not use an exact-scan substitute. Full gate passes 1,467 MoonBit and 23,387 client/corpus tests, three existing skips, zero failures; parser differences fall from 51 to 11 over 38,482 batches.

- [~] Native JSON storage (2026-10-06): fresh construction sizes and storage provenance implemented; 236 captured sizes plus SQL value-carrying contexts pass focused verification. JSON_MODIFY now tracks retained allocation, dictionary/container capacity, deleted-slot order and immutable copies; 485 focused JSON cases pass, including large dictionaries and document-wide storage transitions. Conservative copying, dictionary boundaries, source-format corruption and SELECT disconnects now pass 107 additional registered cases (1,921 combined JSON regressions); other corruption contexts remain under audit. Native variable/UPDATE/MERGE modify statements now pass 121 registered cases and resolve 49 parser gaps; JSON_CONTAINS passes 255 captured cases for native input, advanced paths, collation, comparison modes and error flow. JSON indexes now maintain path entries and use prefix seeks, with 204 focused DDL/catalog/mutation/path/disable-rebuild/internal-catalog cases and two scan-equivalence checks passing. Typed JSON_VALUE RETURNING and JSON_QUERY WITH ARRAY WRAPPER pass 180 captured cases, resolving 63 syntax gaps; two type-dependent 102 diagnostics remain parser-only differences, with full emulator behavior verified. Ordinary native JSON_VALUE/JSON_QUERY advanced accessors now pass 48 registered captures (63 with json3/json4 regressions). Native OPENJSON root/WITH accessors pass 200 registered cases (215 with json3/json4); native function/variable/column mutation accessors pass 300 registered cases (1,814 combined JSON regressions), including retained-allocation errors and batch flow. Broader index options, internal storage, value/range access and concurrency remain under audit; see `docs/reference/json.md`.

- [~] Vector graph pruning (2026-10-07): pure cosine/Euclidean/dot pruning passes 1,476 ordered neighbor lists from 48 repeated oracle fixtures, including positional resumption, degree 48, zero/identical vectors and signed INT keys. Candidate sorting, full builder/search integration and embeddings remain open; see [vector contracts](../reference/vector.md). Full gate passes 1,515 MoonBit and 23,387 client/corpus tests, three existing skips, zero failures.

- [~] Vector graph traversal (2026-10-07): query-time L/M parameters and batched expansion implemented in a pure core component. Twelve captured graphs exercise 324 searches across three metrics and dimensions 3–16; 252 compare exact results, while 72 all-tied queries check count, distances and distinct source keys. Independent oracle rebuilds confirm variation in graph edges and tied selections. Actual SQL index construction/search integration remains open; see [vector contracts](../reference/vector.md). Full gate passes 1,527 MoonBit and 23,387 client/corpus tests, three existing skips, zero failures.

- [~] Vector graph builder and seed (2026-10-07): pure components reconstruct 30,308 neighbor sets across 34 oracle graphs and reproduce 68 searches over the rebuilt graphs. Coverage includes float16, actual page/DOP alignment and 5,000-row batch growth. There are 88 exact seed checks, with 75 standalone seed/boundary captures independently repeated. The graph retains an immutable lookup for searches/snapshots. SQL integration, repeatable sampling beyond 10,000 rows, larger growth thresholds and tied seed/candidate selection remain open; see [vector contracts](../reference/vector.md). Full gate passes 1,615 MoonBit and 23,387 client/corpus tests, three existing skips, zero failures.


- [~] SQL vector index/search integration (2026-10-07): 137 focused captured cases pass and are registered, covering construction, catalogs, query metadata/aliases, DML restrictions, table changes and rollback. Integrated builds include all metrics, float16/float32, DOP 1/32 and 5,000 rows. Tied cosine queries verify count, uniqueness and distance invariants independently repeated against the oracle. Larger sampling, tied seeds, further lifecycle/locking/module contracts and embeddings remain open; see [vector contracts](../reference/vector.md). Full gate passes 1,615 MoonBit and 23,524 client/corpus tests, three existing skips, zero failures; parser checks 40,252 batches with 11 known differences.
