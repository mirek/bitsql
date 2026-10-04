# Database and session settings

SQL Server 17.0.5005.3. Derived from captures in `harness/corpus/settings/`
(`alter-database.sql`, `database-collation.sql`, `rcsi.sql`,
`snapshot-isolation.sql`, `utf8.sql`, generated `dateformat` / `language`
cases from `harness/gen/settings.mjs`) and the msduck imports
(`gaps-unicode-predicates`, `gaps-transactions`, `savepoint`,
`soundex-difference`, `cursor`, `unicode-case`, `windows-1252-best-fit`).
Implementation: `src/core/session/database_options.mbt`,
`set_options.mbt`, `src/core/types/date_settings.mbt`, `utf8.mbt`,
`case_map.mbt`. String → date rules under other date orders and
languages: [date-strings.md](date-strings.md#dateformat-and-language).

## ALTER DATABASE

| Statement | Result |
| --- | --- |
| success | DONE CurCmd 215, no count; `COLLATE` on the current database also sends ENVCHANGE SQL_COLLATION first |
| unknown collation | 448 state 3 at compile time: DONE 253, the batch ends |
| `COMPATIBILITY_LEVEL` not 100..170 step 10 | 15048 state 1 at compile time (DONE 253) |
| `COMPATIBILITY_LEVEL 150` without `=` | 102 near '150' |
| unknown option word after SET | 102 **state 6** near the word |
| `CURRENT` while in tempdb/model/msdb | 12104 state 2 at compile time |
| unknown database | 5011 (class 14, state 5) + 5069 ALTER DATABASE statement failed; statement-level, DONE 215 with the error bit, the batch goes on |
| inside a transaction | 226 state 6, statement-level (DONE 215), the transaction stays open |
| `MODIFY NAME` | INFO 5021, ENVCHANGE database, INFO 5701 (not emulated: 50100) |

Option effects (sys.databases columns and DATABASEPROPERTYEX follow):
`COMPATIBILITY_LEVEL` (`compatibility_level`), `READ_COMMITTED_SNAPSHOT`
(`is_read_committed_snapshot_on`; DATABASEPROPERTYEX has no such property:
NULL), `ALLOW_SNAPSHOT_ISOLATION` (`snapshot_isolation_state` 0/1,
`_desc` OFF/ON), `CURSOR_DEFAULT LOCAL|GLOBAL` (`is_local_cursor_default`,
`IsLocalCursorsDefault`), `SINGLE_USER|RESTRICTED_USER|MULTI_USER`
(`user_access` 1/2/0, `UserAccess`), `READ_ONLY|READ_WRITE` (`is_read_only`,
`Updateability`), `RECOVERY FULL|BULK_LOGGED|SIMPLE` (`recovery_model`
1/2/3, `Recovery`), ON/OFF defaults of the ANSI options (`is_ansi_nulls_on`,
`IsAnsiNullsEnabled`, …). Several options in one SET are applied in order;
`WITH ROLLBACK IMMEDIATE | ROLLBACK AFTER n | NO_WAIT` is accepted.
`READ_COMMITTED_SNAPSHOT ON` needs the database to itself: with a second
connection in the database it fails (5069) unless it can kick them out.

System databases: master and msdb have `snapshot_isolation_state` 1, the
others 0; master/tempdb/msdb are SIMPLE recovery, model and user databases
FULL. (bitsql keeps `ALTER DATABASE CURRENT` allowed in master because
master is the case database of process-isolated harness runs.)

DATABASEPROPERTYEX of the collation: `Collation` (name), `LCID` 1033,
`SQLSortOrder` the SQL sort order id (52 for SQL_Latin1_General_CP1_CI_AS,
0 for Windows collations), `ComparisonStyle` IgnoreCase 1 + IgnoreAccent 2
+ IgnoreKanaType 65536 + IgnoreWidth 131072 (CI_AS 196609, BIN2 0).

## The database default collation

`CREATE DATABASE … COLLATE c` / `ALTER DATABASE … COLLATE c` change what
"coercible-default" means in that database:

- string literals, variables, parameters (also RPC parameters) and
  sp_executesql texts take the database collation;
- new columns of tables, table variables and table types default to it;
  `#temp` tables take **tempdb's** collation (the server's); existing
  columns keep theirs;
- the database's catalog views (sys.objects, sys.columns, …,
  INFORMATION_SCHEMA) report it on their name columns and compare with it
  (`WHERE name = 'T'` misses `t` under a CS collation); server views
  (sys.databases, sys.syslanguages, DMVs, sys.time_zone_info) keep the
  server collation; `type_desc`-like columns keep
  Latin1_General_CI_AS_KS_WS;
- object names resolve under it: `OBJECT_ID('AFTER_ALTER')` is NULL for
  `after_alter` under Latin1_General_100_CS_AS (bitsql: tables and
  OBJECT_ID; column names still resolve case-insensitively);
- savepoint names compare under it;
- `USE` always sends ENVCHANGE SQL_COLLATION (after ENVCHANGE database and
  INFO 5701) and completes with CurCmd 226; inside EXEC(…) neither
  ENVCHANGE nor INFO is sent.

## READ_COMMITTED_SNAPSHOT and SNAPSHOT

- RCSI on: READ COMMITTED reads take no S lock and see the last committed
  state as of the statement's start (a writer's uncommitted change is not
  seen, no blocking); in a transaction each statement sees newer commits.
  `WITH (READCOMMITTEDLOCK)` and `UPDLOCK` reads, and writers, still wait.
  REPEATABLE READ / SERIALIZABLE are unchanged. DBCC USEROPTIONS reports
  `isolation level` = `read committed snapshot`; sys.dm_exec_sessions
  `transaction_isolation_level` stays 2.
- A lock timeout (1222) in a SELECT comes after its COLMETADATA, without
  INFO 3621 (DML gets 3621).
- SNAPSHOT isolation without `ALLOW_SNAPSHOT_ISOLATION ON`: the first
  statement that reads or writes a table fails with **3952** "Snapshot
  isolation transaction failed accessing database '…' because snapshot
  isolation is not allowed in this database. Use ALTER DATABASE to allow
  snapshot isolation." after its COLMETADATA; the batch ends and an open
  transaction is rolled back. With the option, a SNAPSHOT transaction
  keeps reading its start state and does not block on writers.

## READ_ONLY

Any write to the database's tables or catalog (INSERT, CREATE TABLE, …) is
**3906** "Failed to update database "…" because the database is
read-only." at compile time (DONE 253, the batch ends); temp tables and
table variables stay writable.

## DBCC USEROPTIONS

Result set `Set Option` nvarchar(128), `Value` nvarchar(46), both nullable,
server collation; rows in this order, ON flags only: textsize, language
(@@LANGUAGE), dateformat, datefirst, lock_timeout, quoted_identifier,
arithabort, nocount, ansi_null_dflt_on, xact_abort, ansi_warnings,
ansi_padding, ansi_nulls, concat_null_yields_null, isolation level. DONE
CurCmd 230 with the row count (@@ROWCOUNT), then INFO 2528 "DBCC execution
completed. If DBCC printed error messages, contact your system
administrator." and a second DONE 230, unless `WITH NO_INFOMSGS`.

## UTF-8 collations

`Latin1_General_100_{CI|CS}_{AS|AI}[_KS][_WS]_SC_UTF8` and
`Latin1_General_100_BIN2_UTF8` (also `_140_`); without `_SC` the name is
invalid (448). On the wire: collation flag 0x40 (flags 77 for CI_AS_SC_UTF8,
96 for BIN2_UTF8), and char/varchar/text values travel as UTF-8. varchar
holds any Unicode text:

- `varchar(n)` / `char(n)` count UTF-8 bytes: inserting 14 bytes into
  varchar(10) is 2628 with `Truncated value: 'ééééé'`; CAST to varchar(5)
  keeps whole characters (`'ééééé'` → `'éé'`, 4 bytes); char(4) of `'é'`
  pads to 4 bytes (`'é  '`);
- DATALENGTH, CONVERT to varbinary, HASHBYTES and COMPRESS use the UTF-8
  bytes; LEN counts characters (a surrogate pair once, `_SC`);
- relabeling with COLLATE converts between code pages: a CP1252 value
  keeps its characters, a UTF-8 value COLLATE'd to a CP1252 collation goes
  through best fit (`'😀'` → `'??'`); a CP1252 CAST before the COLLATE has
  already lost the characters;
- CAST/CONVERT of character data keeps the input's collation;
- result types: UPPER/LOWER are varchar(8 × n) up to 8000 (also of char),
  LEFT/RIGHT/SUBSTRING keep the source length (varchar(10) for
  LEFT(varchar(10), 2)), concatenation adds lengths;
- comparisons and LIKE follow the Unicode rules of the collation (like
  nvarchar).

Not modelled: CHECKSUM of UTF-8 varchar under linguistic collations (50100),
`CHARINDEX('€', utf8_column)` (a CP1252 literal that does not round-trip is
0 on the oracle), `CHAR(233) COLLATE …_UTF8` (`' '`).

## Case mapping

UPPER/LOWER of nvarchar map every UTF-16 unit by the collation's table
version: version-0 collations (SQL_Latin1_General_CP1_*, Latin1_General_*)
change 1326 units, version-100 collations 1764 (all `_100` variants alike,
BIN2 included), from the captured msduck `unicode-case` tables
(`scripts/gen-case-map.py`). Surrogates and supplementary letters are
unchanged.

## Session SET options (2026-10-04, corpus `tail/settings-*`, msduck-runs session-property-context)

- `SET ANSI_NULLS OFF`: `=`, `<>`, `!=` are two-valued when one operand is
  a NULL literal (also parenthesized) or a bare variable/parameter (`NULL =
  NULL` true, `1 <> NULL` true). Column = column, `@v + 1`, `CAST(NULL AS
  int)`, ISNULL(...) and `<`/`>`/BETWEEN stay three-valued. IN lists and
  simple CASE compare per item; IN / `= ALL|ANY` / `<> ALL|ANY` over a
  subquery treat NULL as equal to NULL even between columns. RPC
  parameters behave like variables.
- Modules capture ANSI_NULLS and QUOTED_IDENTIFIER at CREATE/ALTER
  (procedures, views, functions, triggers; tables capture ANSI_NULLS).
  Inside a procedure `SET ANSI_NULLS` has no effect and sends no DONE;
  SESSIONPROPERTY and `@@OPTIONS & 32` show the module's value; dynamic SQL
  inherits it. sys.sql_modules.uses_ansi_nulls / uses_quoted_identifier,
  sys.tables.uses_ansi_nulls, OBJECTPROPERTY IsAnsiNullsOn /
  ExecIsAnsiNullsOn / IsQuotedIdentOn / ExecIsQuotedIdentOn report them
  (Exec* is NULL for tables).
- `@@OPTIONS` bits: ANSI_WARNINGS 8, ANSI_PADDING 16, ANSI_NULLS 32,
  ARITHABORT 64, ARITHIGNORE 128, QUOTED_IDENTIFIER 256, CONCAT_NULL_YIELDS_NULL
  4096, NUMERIC_ROUNDABORT 8192 (login default 5496).
- QUOTED_IDENTIFIER is a parse-time option: every `SET QUOTED_IDENTIFIER`
  in a batch applies while parsing, so `SET … OFF; SELECT
  SESSIONPROPERTY('QUOTED_IDENTIFIER'); SET … ON` reads 1.
- Not modelled (Emulator errors): string `+` under CONCAT_NULL_YIELDS_NULL
  OFF (`'a' + NULL` is 'a'), decimal/money/float expressions under
  NUMERIC_ROUNDABORT ON (rounding is 8115 state 7), char/varchar/binary/
  varbinary columns created under ANSI_PADDING OFF (trailing blanks/zeros
  dropped, nullable char too, is_ansi_padded 0), double-quoted strings under
  QUOTED_IDENTIFIER OFF, XML methods and DML on tables with filtered or
  computed-column indexes under any non-default index option (SQL Server:
  1934 "… following SET options have incorrect settings: 'ANSI_NULLS,
  ANSI_PADDING'", batch ends).
- sp_set_session_context checks, in order: 16914/16903 argument count
  (message names sp_set_connection_context), 225 NULL key, 15666 empty or
  over-256-byte key, 15600 NULL @read_only or max-type value, 15664
  read-only key; failures return 1 with the DONEPROC error bit; under TRY
  ERROR_PROCEDURE() is sys.sp_set_session_context. Keys match ignoring case
  and trailing spaces except that the last character must match exactly
  ('email' found by 'Email', not by 'EMAIL'). SESSION_CONTEXT of varchar or
  NULL is 8116.
