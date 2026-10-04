# System catalog rows and catalog procedures

Rules derived from captures in long-tail round 4 (2026-10-04; msduck
gaps-catalog, msduck-runs system-all-columns / all-objects / index-catalog /
drop-index / table-type-catalog / tedious-compat-gaps, corpus
`tail/catalog-*`). Implementation: `session/system_catalog.mbt`,
`sp_rename.mbt`, `alter_index.mbt`, generated `sysviews_system_data.mbt`.

## System objects and columns

- `sys.system_objects`: 2637 rows in schemas 3 (INFORMATION_SCHEMA) and 4
  (sys); `principal_id` NULL, `parent_object_id` 0, `is_ms_shipped` 1, not
  published. `sys.system_columns`: 11569 rows; every flag is constant except
  `is_nullable` and `is_ansi_padded`. Dumped from the oracle by
  `harness/src/dump-system-catalog.mjs` into `scripts/system-catalog/*.tsv`
  and generated into MoonBit by `scripts/gen-sysviews.py`.
- `sys.all_objects` = `sys.objects` ∪ `sys.system_objects`; `sys.all_columns`
  = `sys.columns` ∪ `sys.system_columns`. `OBJECT_ID(N'sys.columns')`
  resolves system views.
- Descriptor differences: `all_objects.type` has flags 33 while
  `system_objects.type` has 8; most `system_columns` bit columns have flags
  32 (`tail/catalog-view-descriptors-system`).
- `sys.server_principals`: 31 rows (sa, public, fixed and `##MS_*##` roles,
  certificate and Windows logins). sa's sid is 0x01, type S / SQL_LOGIN,
  default database master, language us_english; `SUSER_SNAME(0x01)` = 'sa'.
- `sys.database_files` of a fresh user database: `<db>.mdf` and
  `<db>_log.ldf` under `/var/opt/mssql/data/`, 1024 pages, growth 8192, log
  max_size 268435456; master has 600 / 352 pages, 10% growth and a NULL
  `file_guid` (bitsql derives a stable guid for user databases: SQL Server's
  is random; tempdb/model/msdb raise 50100).
- A table type's table is a `sys.objects` row in schema sys named
  `TT_<type>_<object id as 8 hex digits>`, type TT / TYPE_TABLE,
  `is_ms_shipped` 1; `COL_NAME` works on it, `OBJECT_ID('x', 'TT')` is NULL
  (corrects the 2026-10-03 note "no sys.objects row").
- User object ids of a fresh database start at 1221579390 and step by
  16000057; a failed `ALTER TABLE ADD` consumes none.

## sp_rename

- Argument checks before its transaction starts, in this order: NULL
  @newname 15223 state 11 (line 96), NULL @objname 15223 state 1 (line 101),
  empty @newname 15004 (line 17) then 15224 state 15 (line 109), unknown
  @objtype 15249 (line 90). Other failures send BEGIN/COMMIT TRAN before the
  ERROR.
- 15248 echoes @objtype as written at line 269 (COLUMN), 450 (INDEX) or 620
  (OBJECT); without @objtype the miss is 15225. 15336 (class 16) at line
  774 for a column referenced by a CHECK, a computed column or a
  schema-bound view, line 794 for a table referenced by a schema-bound view.
- Renaming a computed column: the 15477 caution, 4928, DONEINPROC 170,
  status 1. A column of a filtered index: 5074 then 4922 state 9.
- After a failure outside TRY @@ERROR is 0; under TRY ERROR_PROCEDURE() is
  'sp_rename' with the procedure's line. Without @objtype the name is tried
  as an object, then `table.column`, then `table.index`. 15335 says "as a
  INDEX name" / "as a object name".
- Not emulated (50100): @objtype DATABASE, USERDATATYPE, STATISTICS.

## sp_pkeys / sp_fkeys

- Arguments are compared exactly, not as LIKE patterns (`'v2_%'`, `'k_'`,
  `'%'` find nothing). sp_pkeys without arguments is 201; unknown parameters
  8145; too many arguments 8144.
- A qualifier naming another database: 15250, status -6 (sp_pkeys at line
  17 then DONEINPROC 219, @@ERROR stays 15250; sp_fkeys line 28 for the FK
  qualifier, 37 for the PK one). sp_fkeys without table names: 15252 at
  line 20. Without @pktable_name, UPDATE_RULE / DELETE_RULE are 0 (CASCADE)
  or 1.

## ALTER INDEX / DROP INDEX

- ALTER INDEX completes with CurCmd 337; a missing index is 2727 (class
  11), a missing table 1088 state 9. A disabled unique index accepts
  duplicates and its REBUILD then fails with 1505 + 3621 (CurCmd 253);
  REORGANIZE of a disabled index is 1973; `ALL … REBUILD` re-enables every
  index; `REBUILD WITH (FILLFACTOR = n)` sets fill_factor. Disabling a
  clustered index and `ALTER INDEX … SET (…)` raise 50100.
- DROP INDEX without a table is 159 (class 15); 3701 state 6 for a missing
  table, 7 for a missing index; indexes dropped earlier in the same list
  stay dropped; `WITH (ONLINE = OFF)` is accepted on a nonclustered index;
  the lowest free index_id is reused.

## Column definitions

- Precision/scale out of range: 183 (class 15) "The scale (s) for column
  'c' must be within the range 0 to p." or 2750 "Column or parameter #n: …
  maximum precision of 38/53"; a zero length or precision 1001 "Line n: …"
  (class 15); a fractional-seconds scale above 7 is 1002; both at the
  type's line.
- 2705 compares names under the database collation ([Ä] and [ä] collide),
  state 3 within one CREATE TABLE / TYPE / table variable, 4 for ALTER
  TABLE ADD. CREATE TYPE named like a system type is 219.
- `lob_data_space_id` is 1 for xml/text/ntext/image too and stays 1 after
  a LOB column is dropped or altered back (sticky part not implemented).
