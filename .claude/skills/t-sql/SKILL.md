---
name: t-sql
description: "Comprehensive T-SQL language reference for implementing a T-SQL engine. Covers data types, type conversion, operators, expressions, control flow, queries (SELECT, JOIN, CTE, window functions), DML statements (INSERT, UPDATE, DELETE, MERGE), DDL statements (CREATE/ALTER/DROP TABLE, INDEX, VIEW, PROCEDURE, FUNCTION, TRIGGER), built-in functions (aggregate, string, math, date/time, conversion, JSON), transactions, error handling, and session settings. Use when implementing T-SQL parsing, evaluation, query processing, or SQL Server compatibility."
---

> **Provenance.** Reference content ported from the sibling projects msduck and
> mssqlite (same author, public domain). Notes that mention `packages/*`,
> `mssqlite`, `msduck`, SQLite or DuckDB describe *those* implementations. They
> are field notes verified against SQL Server there, not claims about bitsql.
> Real SQL Server captures remain the authority (docs/design/verification.md).

## bitsql implementation

`src/core/ast` (AST, spans, SyntaxError), `src/core/lex` (lexer, GO splitter), `src/core/parse` (parser), `src/core/bind` (binder, `tsql.mbt` Semantics), `src/core/exec` (executor), `src/core/types` (values and conversions).

## bitsql findings (keep current)

Append dated, one-paragraph findings here whenever bitsql work confirms,
corrects or adds to this reference: wire bytes, client behavior or SQL Server
semantics observed in captures. Correct wrong inherited notes in place and
mention the correction here.

- 2026-10-03 (triggers, corpus `triggers/`): XACT_ABORT is implied inside
  triggers, but RAISERROR never honors XACT_ABORT (no rollback, no batch
  abort; THROW does). In autocommit the trigger runs inside an implicit
  transaction (@@TRANCOUNT 1); its ROLLBACK undoes the firing statement, the
  trigger finishes, then 3609 "The transaction ended in the trigger. The batch
  has been aborted." ends the batch, with no ENVCHANGE. OUTPUT without INTO on
  a table with any enabled trigger is 334. INSTEAD OF INSERT's DONE count is
  the original row count even if the trigger inserts nothing. Nested trigger
  TRIGGER_NESTLEVEL() is 1, 2, ….

- 2026-10-03: transaction semantics as implemented (partly unverified, check
  against the gaps-transactions captures): XACT_ABORT ON + error inside TRY
  dooms the transaction (XACT_STATE() = -1); writes and COMMIT then raise 3930;
  a doomed transaction open at the end of a request (batch *or* RPC — tedious
  execSql is an RPC) is rolled back with 3998. Table variables keep their rows
  after ROLLBACK, temp tables do not.
- 2026-10-03: parse differential (`npm run parse-diff`) over all 1707 captured
  corpus batches agrees with SQL Server. Fixes it forced: `TRIM([LEADING|TRAILING|BOTH]
  chars FROM s)` (parsed as TRIM/LTRIM/RTRIM(s, chars)); RAISERROR arguments are
  constants/variables only. Negative number literals are fine everywhere, NULL
  only as a substitution argument (NULL message/severity = 156); `+1`, `-@x`,
  `(1)` and `1+2` are 102. `OUTPUT *` is 102 near '*'. An empty `BEGIN TRY END TRY`
  is 102 near 'TRY'.
- 2026-10-03: JSON functions are *streaming*: JSON_VALUE/JSON_QUERY validate
  only up to the selected value (`{"a":1,"b":x}` with `$.a` returns `1`), but a
  missing path validates the whole document and reports 13609 instead of NULL.
  A root scalar document is 13609 even for `$`. 13609/13607 messages read
  "Unexpected character 'c' is found at position N." (0-based UTF-16 index,
  `'.'` at end of input). Implemented in `src/core/json`; evidence: msduck
  `reference/json-extraction-boundaries.json` → `src/core/json/captured_test.mbt`.
- 2026-10-03 (parser): reserved words follow SQL Server's official list, so
  `THROW`, `OUTPUT`, `USING`, `OFFSET`, `TRY`, `CATCH` are *not* reserved.
  Consequences that match SQL Server: `SELECT 1 THROW 50000, 'x', 1` takes
  THROW as a column alias and fails near '50000'; `ROLLBACK TRANSACTION THROW`
  rolls back to a savepoint named THROW; MERGE's target alias must special-case
  `USING`. This corrects the inherited mssqlite note that treats USING/OUTPUT
  as reserved.
- 2026-10-03 (parser): msduck captures confirm message shapes: errors near a
  reserved keyword are 156 "Incorrect syntax near the keyword 'x'." using the
  token as written (e.g. 'values', 'ORDER'); others are 102. A CTE after an
  unterminated statement is 319 with the long "previous statement must be
  terminated with a semicolon" text. Modules not first in a batch are 111
  "'CREATE/ALTER PROCEDURE' must be the first statement in a query batch."
  (procedures use that combined name; functions say 'CREATE FUNCTION').
  `ERROR_PROCEDURE(*)` is 102 near '*': only COUNT/COUNT_BIG/CHECKSUM/
  BINARY_CHECKSUM take `*`. Duplicate FOR XML options report near 'XML'.
- 2026-10-03 (parser): at end of input SQL Server reports the last token
  ("SELECT * FROM" → near the keyword 'FROM'); bitsql does the same. Not yet
  verified against captures: the exact error for statements after CREATE
  VIEW/FUNCTION in the same batch (bitsql: 156/102 near the next token), THROW
  after an unterminated statement (bitsql: 102 near 'THROW'), empty
  `BEGIN END` (bitsql: 156 near 'END'), unclosed `[ident` (bitsql: 105).
- 2026-10-03 (parser): `IF c stmt; ELSE stmt` is legal (the `;` before ELSE is
  consumed). Bare `TOP n` takes only a numeric literal; UPDATE/DELETE/INSERT
  require `TOP (expr)`. EXEC arguments are restricted to literals, variables,
  DEFAULT, NULL and bare words (passed as strings): `EXEC p 1 + 1` is 102.
- 2026-10-03 (src/core/types, from msduck captures): **string → integer**
  trims only ASCII spaces (tab, CR/LF, NBSP, NUL, fullwidth digits fail);
  a sign may be followed by spaces (`'+ 7'` = 7); `''`, `'   '`, `'+'`, `'-'`
  are 0. Failures: tinyint/smallint/int → 245 state 1 "Conversion failed
  when converting the nvarchar value '…' to data type int."; **bigint →
  8114 state 5 "Error converting data type nvarchar to bigint."** Overflow:
  tinyint 244/1 "…overflowed an INT1 column. Use a larger integer column.",
  smallint 244/2 (INT2), int 248/1 "…overflowed an int column.", bigint
  8115/2. Sources over 4000 UTF-16 units raise 8152 state 10 even in
  TRY_CAST. Messages use the bare type name for max sources (`nvarchar`),
  while 529/257/206/8117 print `nvarchar(max)` (reference/unicode-integer.json).
- 2026-10-03: integer arithmetic: overflow is 8115 **state 2**, `MIN / -1`
  **and `MIN % -1`** overflow too; `x/0`, `x%0` → 8134 state 1; NULL / 0 is
  NULL; `/` truncates toward zero, `%` has the dividend's sign
  (reference/checked-integer.json, integer-overflow.json).
- 2026-10-03: **decimal division truncates** at the result scale (2/3 as
  decimal(13,8) = 0.66666666); overflow says "data type numeric" even for
  DECIMAL operands (8115/2). Integer literals next to a decimal are typed
  decimal(digits,0) by the binder: `2/2147483649` is numeric(12,11), but
  `CAST(.. AS DECIMAL(5,2))/CAST(3 AS INT)` is decimal(16,13). NUMERIC with
  INT stays numeric (reference/decimal-division.json,
  numeric-arithmetic-context.json, numeric-literal-metadata.json).
- 2026-10-03: **float → text** (CAST and CONVERT style 0) is `%.6g` with a
  3-digit exponent (`1e+006`, `9.94922e-044`), computed by first rounding
  the exact binary value to **17 significant digits**, then half away from
  zero to 6: 1.2345749999999999779… prints `1.23458`. This matches all 2,170
  grid values (reference/float-default-grid.json); exact rounding fails 14,
  15/16-digit intermediates fail more. The float → int overflow message uses
  the same 17 digits: 232 state 3 "Arithmetic overflow error for type int,
  value = 1000000000000000000000000000000.000000." for 1e30.
- 2026-10-03: temporal text (reference/temporal-guid-format.json,
  us_english): CAST of date/time/datetime2/datetimeoffset is ISO with exactly
  the declared fraction digits (`2024-03-01 00:00:00.00 +01:30`), but CAST of
  datetime/smalldatetime and explicit style 0 of every type is `Mon dd yyyy
  hh:miAM` with space-padded day and hour (`Jan  2 2024  3:04AM`, time alone
  `11:59PM`, offset appended). Style 121 uses the declared digits (3 for
  datetime and smalldatetime, `.000` for the latter). String → DATETIME2(0)
  of `…23:59:59.9999999` rounds into the next day, but → TIME(0) gives
  `23:59:59` (no wrap). Legacy datetime rounds to 1/300 s (.001→.000,
  .002→.003, .005→.007, .998→.997, .999→next second); smalldatetime rounds
  at 30 s *after* that (29.998 down, 29.999 up). Out of range: 242 state 3
  "The conversion of a varchar data type to a smalldatetime data type
  resulted in an out-of-range value."; datetimeoffset whose local or UTC
  instant leaves 0001..9999: 8114 **state 31** "Error converting data type
  varchar to datetimeoffset.".
- 2026-10-03: uniqueidentifier: text is uppercase; storage bytes are
  Data1/2/3 little-endian; ORDER BY compares storage bytes 10–15, then 8–9,
  6–7, 4–5, 0–3 (reference/guid-conversion-order.json). Text → GUID accepts
  a canonical 36-char prefix (rest ignored) or `{…}` (rest after `}`
  ignored); otherwise 8169 state 2.
- 2026-10-03: linguistic collations on nvarchar (reference/unicode-collation.json):
  NUL is ignorable, tab/NBSP/ZWSP are not; é = e+U+0301, ß = ss, æ = ae,
  œ = oe; fullwidth = ASCII and katakana = hiragana even in CS_AS; CS orders
  lower before upper (Σ > ς); İ > i and ı > I under CI. Version-0 tables
  (SQL_Latin1_General_CP1_*, Latin1_General_*) treat every surrogate unit
  and U+FFFD as ignorable; _100 sorts them above the BMP. BIN2 pads the
  shorter operand with spaces before comparing code units ('a' > 'a'+NUL).
- 2026-10-03 (query language, `harness/corpus/query/*`): aggregate result
  types — COUNT int, COUNT_BIG bigint, SUM/AVG of tiny/small/int → int,
  bigint → bigint, decimal(p,s) → SUM decimal(38,s) / AVG decimal(38,max(s,6))
  (quotient truncated, msduck decimal-avg), money → money, real/float → float;
  MIN/MAX keep the type; STRING_AGG: varchar(n) → varchar(8000), nvarchar(n)
  and non-strings → nvarchar(4000), (n)varchar(max) stays max. All aggregates
  report nullable (flags 1, origin "aggregate"); GROUPING() is NOT NULL
  tinyint flags 32. Errors: SUM/AVG/MIN on bit or SUM on varchar 8117
  ("Operand data type bit is invalid for sum operator."), aggregate in WHERE
  147 (class 15), nested aggregate 130, aggregate in GROUP BY 144, ungrouped
  column 8120 select list / 8121 HAVING / 8127 ORDER BY (double quotes),
  differing WITHIN GROUP orders 8711, scalar subquery >1 row 512, multi-column
  subquery 116, set-op width 205, ORDER BY not in a set-op select list 104,
  WITH TIES without ORDER BY 1062, ROW_NUMBER without ORDER BY 4112, window in
  WHERE 4108, duplicate derived column 8156, unnamed derived column 8155
  state 2 (followed by a second error 207 for the outer reference),
  SELECT INTO existing table 2714 state 6, STRING_SPLIT separator not one
  char 214 state 11 (after COLMETADATA). INFO 8153 (class 0, the statement's
  line) follows the rows; STRING_AGG never triggers it.
- 2026-10-03 (query language): window functions — ranking functions are
  bigint, LAG/LEAD/FIRST/LAST_VALUE keep the argument type, PERCENT_RANK and
  CUME_DIST float, all nullable. Default frame with ORDER BY is RANGE
  UNBOUNDED PRECEDING..CURRENT ROW (peers included). EXCEPT/INTERSECT keep the
  left operand's column metadata (base flags 9), UNION/UNION ALL report flags
  0|nullable; NULL literal branches do not take part in type unification.
  SELECT INTO completes with cmd 194 and the row count; `SELECT @v = …
  FROM` completes with 193 and the number of rows (last row wins). OPENJSON
  `key` is nvarchar(4000) Latin1_General_BIN2 NOT NULL (flags 2), `value`
  nvarchar(max), `type` tinyint NOT NULL; OPENJSON WITH over an object root
  yields one row. STRING_SPLIT `value` takes the input's type and
  nullability, `ordinal` is NOT NULL bigint.
- 2026-10-03: unverified choices in src/core/types (need captures): states
  of 8115 for CAST overflows other than string→numeric (8), arithmetic (2);
  220 "Arithmetic overflow error for data type tinyint, value = 256." for
  int → tinyint/smallint; float → decimal via 17 digits; datetime2 →
  datetime rounding (the inherited table above says "truncated"); TIME
  rounding mid-day; money × / ÷ rounding; binary comparison zero-padding;
  word-sort ('-' and '\'' ignored at primary level) for Windows collations;
  styles other than none/0/121 for temporal types.

- 2026-10-03 (functions, harness/corpus/functions captures): **result
  metadata**: nearly every built-in is nullable (flags 33) even with literal
  arguments (LEN('abc'), UPPER('abc')); exceptions: CONCAT/CONCAT_WS (32),
  *FROMPARTS with integer arguments (32), PI() and SIGN/CEILING/FLOOR/ROUND/
  RADIANS over numeric literals (folded, 32; ABS/POWER/DEGREES are not), NEWID
  is 33. Implicit-to-string lengths: bit 1, tinyint 4, smallint 6, int 12,
  bigint 24, decimal 41, money 40, float 23, date/time types and GUID 40, bare
  NULL 1 (0 inside CONCAT). LEFT/RIGHT/SUBSTRING take min(constant, L)
  (at least 1); REPLICATE L*n capped at 8000 bytes, a count <= 0 types as 2
  bytes, NULL/variable/non-integer counts 8000; SPACE(n) is varchar(n)
  (<= 0 → 1); STUFF(L - deleted + R) for constant start/length, else 8000,
  NULL length → nvarchar(4000); STR(x, n) varchar(n); QUOTENAME nvarchar(258);
  SOUNDEX varchar(5); DATENAME nvarchar(30); FORMAT nvarchar(4000);
  STRING_ESCAPE nvarchar(max); TRANSLATE/REPLACE 8000/4000. ROUND keeps
  decimal(p,s) (overflow 8115 "numeric"), POWER(decimal(p,s)) is (38,s),
  DEGREES/RADIANS of decimal are (38,18), bit/text/NULL arguments become float.
- 2026-10-03 (functions): datepart errors: 9810 "The datepart X is not
  supported by date function F for data type T." with per-function states
  (DATEADD date/time 1, datetime 0, smalldatetime 3, tzoffset/iso_week 2;
  DATEPART date 2, time 3, datetime tzoffset 6; DATENAME 4/5/7; DATETRUNC
  datetime 9, smalldatetime 8, date/time cross parts 10, else 11); DATEDIFF
  iso_week/tzoffset 9806 state 0; overflow 535 state 0 (datediff_big wording);
  DATEADD overflow 517 states date/datetime2/datetimeoffset 3, datetime 1,
  smalldatetime 2; unknown datepart is the *parse* error 155. DATEADD rounds:
  datetime ms to 1/300 s (+1 ms keeps .997, +2 ms → next second),
  smalldatetime seconds to the minute (29 down, 30 up), datetime2 ns to
  100 ns half away from zero then to the scale. DATEDIFF week counts Sunday
  boundaries; text arguments of DATEPART/DATEDIFF are datetimeoffset(7), of
  DATEADD datetime; DATETRUNC of an int is 8116.
- 2026-10-03 (functions): **RAND** is L'Ecuyer's combined generator
  (40014 mod 2147483563, 40692 mod 2147483399, output z * 4.656613e-10) with
  RAND(seed) setting s1 = |seed| (0 or >= 2147483563 → 12345) and s2 = 67890;
  reproduces RAND(n) and the following RAND() values exactly. BINARY_CHECKSUM
  is h = rotl4(h) ^ unit (varchar bytes signed, nvarchar UTF-16 units,
  integers whole, trailing spaces dropped); CHECKSUM of integers likewise
  (bigint as hi ^ lo), of text collation-dependent (not emulated).
  HASHBYTES: MD2 and unknown algorithms return NULL. SOUNDEX treats H/W as
  separators and stops at the first non-letter; DIFFERENCE fits "first letter
  +1, then a's digits in b's: 3 / any 2-run 2 / else 1 per digit" over codes
  built without first-letter dedupe (asymmetric; unverified beyond 26 pairs).
- 2026-10-03 (functions): string search follows the collation:
  LTRIM/RTRIM/TRIM sets match units equal to any substring of the set
  (ß trimmed by 'ss', é by e+U+0301, ignorable surrogates under version-0
  collations), REPLACE(N'straße', 'ss', 'X') is 'straXe', CHARINDEX(N'é',
  N'cafe'+U+0301) is 4 but varchar 'straße' does not contain 'ss'. Runtime
  negative lengths: LEFT/SUBSTRING 537 state 2 ("LEFT or SUBSTRING"), RIGHT
  536 state 4; constant ones 536 state 6 (LEFT/RIGHT) / 8 (SUBSTRING) at
  compile time. ISNUMERIC = float syntax (e/d exponent) or money syntax
  (currency, sign, spaces after the sign, commas, lone '-', '.', ','). STR
  fits decimals to the truncated integer part, keeps '-' on values rounding
  to 0. FORMAT: .NET Framework en-US (negative currency in parentheses, double
  from 15 significant digits, time needs escaped literals or returns NULL).
  Unverified: DIFFERENCE beyond the captured pairs, case mapping beyond
  Latin/Greek/Cyrillic, CHECKSUM of NULL columns, GREATEST nullability rule
  (non-null when every argument is non-null and converts without failure).

# T-SQL Language Reference

Complete reference for the Transact-SQL language used by Microsoft SQL Server.
- 2026-10-03 (user functions, harness/corpus/udf/*): scalar UDF calls need
  the schema (unqualified: 195 state 10); unknown or table-valued names are
  4121 ("Cannot find either column "dbo" or the user-defined function or
  aggregate "dbo.f", or the name is ambiguous."); too many / too few
  arguments 8144 / 313 (state 2 scalar, 3 table-valued; the name as
  written). A parameter default is used only for an explicit DEFAULT
  argument; DEFAULT for a parameter without one is NULL. Incompatible
  argument types are 206 state 2 at bind time, unconvertible values 245 at
  run time after COLMETADATA. Results are nullable computed columns (33).
  Errors inside a scalar or inline function are reported at the calling
  statement's line with ERROR_PROCEDURE() NULL (also WITH INLINE = OFF, so
  not an artefact of scalar UDF inlining). @@NESTLEVEL
  inside is 1; recursion beyond 32 levels is 217 and ends the batch. A
  multi-statement TVF error is followed by 3621; inline/scalar ones are not.
  TVF arity errors (313/8144 state 3) and 216 ("Parameters were not supplied
  for the function 'dbo.f'.") report line 13 when the name is
  schema-qualified, the statement line otherwise. A scalar function in FROM
  is 208 state 224; a TVF column alias list 317. `EXEC @r = dbo.f @x = 5`
  runs a scalar function: DONEINPROC 193 count 1, DONEPROC 224, no
  RETURNSTATUS. CREATE FUNCTION rejects side effects with 443 "Invalid use of
  a side-effecting operator 'X' within a function." — state 15 for INSERT/
  UPDATE/DELETE/MERGE on existing base tables, BEGIN/COMMIT/ROLLBACK
  TRANSACTION, SAVEPOINT, SET OPTION ON/OFF, CREATE TABLE, TRUNCATE TABLE;
  state 14 for PRINT, RAISERROR, THROW, EXECUTE STRING and each of BEGIN TRY/
  END TRY/BEGIN CATCH/END CATCH; state 1 for newid/rand/newsequentialid
  (lower case). All 443s and 444 (SELECT returning data, state 3 scalar / 2
  TVF) are reported together in statement order. Temp tables: 2772. Last
  statement not RETURN: 455 state 2 (a trailing BEGIN...END counts, IF/ELSE
  does not); `RETURN` without value in a scalar function 1075, with a value
  in a TVF 178 (both class 15). DML on a missing table and EXEC of a missing
  procedure are accepted (deferred name resolution; the latter with INFO
  2007).
- 2026-10-03 (result metadata): an ORDER BY key that is not in the select
  list (ORDER token 0) clears the computed flag on all computed columns of
  the SELECT (literal 32 → 0, expression 33 → 1); see
  docs/reference/result-metadata.md. Also seen while capturing: INSERT
  violating a CHECK that references one column names it (", column 'id'.")
  and is followed by INFO 3621; bitsql's INSERT path does neither yet (only
  ALTER TABLE does).

Source https://learn.microsoft.com/en-us/sql/t-sql/language-reference?view=sql-server-ver17

## Reference Files

- [data-types.md](data-types.md) — All data types (exact/approximate numeric, date/time, character, binary, special), storage sizes, ranges, precision/scale rules, type precedence, type synonyms
- [type-conversion.md](type-conversion.md) — CAST/CONVERT with style codes, TRY_CAST/TRY_CONVERT, implicit/explicit conversion matrix, decimal arithmetic precision rules, truncation vs rounding behavior
- [language-elements.md](language-elements.md) — Operators (arithmetic, comparison, logical, bitwise, string, compound, unary), operator precedence, expressions, CASE, LIKE wildcards, BETWEEN/IN/EXISTS/ALL/ANY, variables (DECLARE/SET/SELECT), control flow (IF/ELSE, WHILE, BEGIN/END, GOTO, RETURN, WAITFOR), cursors, reserved keywords, NULL and three-valued logic
- [queries.md](queries.md) — Logical processing order, SELECT clause, FROM/JOIN types and semantics (INNER/LEFT/RIGHT/FULL/CROSS, APPLY, PIVOT), WHERE/search conditions, GROUP BY (ROLLUP/CUBE/GROUPING SETS), HAVING, ORDER BY with OFFSET/FETCH, TOP, OVER clause / window frames (ROWS vs RANGE), CTEs (recursive and non-recursive), set operations (UNION/EXCEPT/INTERSECT), subqueries, OUTPUT clause, SELECT INTO, table value constructor, hints, AT TIME ZONE
- [functions.md](functions.md) — Aggregate functions (COUNT, SUM, AVG, MIN, MAX, STRING_AGG, STDEV, VAR), ranking/window functions (ROW_NUMBER, RANK, DENSE_RANK, NTILE, LAG, LEAD, FIRST_VALUE, LAST_VALUE, PERCENT_RANK, CUME_DIST, PERCENTILE_CONT/DISC), string functions (SUBSTRING, LEN, REPLACE, CONCAT, UPPER, LOWER, TRIM, LEFT, RIGHT, CHARINDEX, PATINDEX, REVERSE, REPLICATE, STUFF, SPACE, CHAR, NCHAR, ASCII, UNICODE), math functions (ABS, CEILING, FLOOR, ROUND, POWER, SQRT, SIGN), date/time functions (GETDATE, DATEADD, DATEDIFF, DATEPART, DATENAME, DATEFROMPARTS, FORMAT), logical functions (IIF, CHOOSE, ISNULL, COALESCE, NULLIF), system functions (NEWID, DB_NAME, OBJECT_ID, @@ERROR, @@ROWCOUNT, SCOPE_IDENTITY, @@TRANCOUNT), JSON functions (JSON_VALUE, JSON_QUERY, JSON_MODIFY, ISJSON, OPENJSON), error functions (ERROR_MESSAGE/NUMBER/SEVERITY/STATE/LINE/PROCEDURE), ISNUMERIC, ISDATE, DATALENGTH
- [statements-ddl.md](statements-ddl.md) — CREATE/ALTER/DROP TABLE (column definitions, constraints, IDENTITY, computed columns, foreign key actions), CREATE INDEX (clustered/nonclustered, UNIQUE, filtered, INCLUDE, options), CREATE VIEW (SCHEMABINDING, CHECK OPTION, updatable views), CREATE PROCEDURE (parameters, OUTPUT, RECOMPILE), CREATE FUNCTION (scalar, inline TVF, multi-statement TVF), CREATE TRIGGER (AFTER/INSTEAD OF, DML/DDL, inserted/deleted tables), CREATE DATABASE, CREATE SCHEMA, GRANT/DENY/REVOKE permissions
- [statements-dml.md](statements-dml.md) — INSERT (VALUES, SELECT, EXEC, DEFAULT VALUES, OUTPUT), UPDATE (SET, compound operators, FROM clause for multi-table, .WRITE for LOB), DELETE (FROM...FROM pattern, join-based), MERGE (MATCHED/NOT MATCHED, $action), TRUNCATE TABLE (vs DELETE, IDENTITY reset, restrictions), BULK INSERT (format options, constraints, triggers)
- [transactions-and-error-handling.md](transactions-and-error-handling.md) — Transaction modes (autocommit/explicit/implicit), BEGIN/COMMIT/ROLLBACK TRANSACTION, SAVE TRANSACTION/savepoints, @@TRANCOUNT semantics, XACT_STATE(), TRY...CATCH (severity rules, error functions, uncommittable transactions), THROW vs RAISERROR, SET statements (ANSI_NULLS, QUOTED_IDENTIFIER, NOCOUNT, XACT_ABORT, IDENTITY_INSERT, TRANSACTION ISOLATION LEVEL, ARITHABORT, CONCAT_NULL_YIELDS_NULL, and more), isolation levels

## Inherited notes: @mssqlite/tsql + transpile + engine implementation in mssqlite (not bitsql)

The language pipeline lives in three packages:

- [`packages/tsql`](../../../packages/tsql) — lexer + parser to a typed
  AST. Its Readme lists the exact supported surface (queries with joins/
  CTEs/set ops/window OVER, full expression precedence and predicates,
  DML, DDL with constraints, DECLARE/SET, control flow, transactions,
  EXEC, THROW).
- [`packages/transpile`](../../../packages/transpile) — AST → SQLite SQL
  with function mapping and CONVERT style support.
- [`packages/engine`](../../../packages/engine) — interprets what SQLite
  cannot: variables, IF/WHILE, @@TRANCOUNT nesting, sp_executesql,
  SELECT INTO, error-number mapping. Its server-facing async execution checks
  an AbortSignal between statements and on every interpreted loop iteration;
  Attention is control flow, not a catchable T-SQL error.

### Parsing notes discovered implementing

- Reserved words must be rejected as bare identifiers (else
  `SELECT FROM` "succeeds" selecting a column named FROM) but allowed as
  function names directly before `(` — `LEFT(x, 1)`, `RIGHT(...)`.
- `TOP 10 *` is ambiguous with multiplication: binary-operator parsing
  must rewind when the right operand fails so `*` can be the select star.
  Bare `TOP n` only takes a constant; expressions require `TOP (expr)`.
- `CASE x WHEN …` vs `CASE WHEN …`: the optional operand parser must not
  swallow the `WHEN` keyword as a column reference.
- `GO` is a client-side batch separator — it never arrives over TDS and
  is deliberately not in the grammar.
- Statements separate on semicolons *or* juxtaposition; both appear in
  real client traffic.
- `@@ERROR` reads as the previous statement's error number — it resets
  *after* the statement referencing it, and it persists across batches.

### Implementation notes — later additions

- TRY/CATCH parses in `beginBlockOrTransaction` (BEGIN TRAN → BEGIN TRY →
  block, in that order); bodies terminate on the two-word `END TRY` /
  `END CATCH`, so nested plain `BEGIN … END` blocks parse through
  `statementRef` and never confuse the terminator scan.
- RAISERROR takes a parenthesized argument list plus optional
  `WITH option[, …]` (options parsed, lowercased, NOWAIT/LOG ignored).
- Batch execution classifies failures after each top-level statement.
  Constraint violations (515/547/2601/2627), conversion/arithmetic classes,
  RAISERROR severity 11-19, and cursor/sequence runtime errors emit an ERROR
  and continue; syntax/compile failures, explicit THROW, unsupported operations,
  and severity 20+ abort. `@@ERROR` exposes the immediately prior failure and
  `@@ROWCOUNT` is 0 after it. XACT_ABORT ON rolls back and aborts for qualifying
  runtime errors, but—as on SQL Server—does not change RAISERROR behavior.
  TRY/CATCH intercepts errors before this outer classification.
  Integer CAST/CONVERT truncates numeric/decimal inputs toward zero and treats
  empty or whitespace-only character input as zero. Other invalid text and type
  bounds retain 245/8115; TRY variants convert either failure to NULL.
- Integer `+ - * / %` uses checked evaluation: NULL propagates, integer division
  truncates toward zero, zero divisors raise 8134, and inferred int/bigint bounds
  raise 8115. SUM defaults to SQL Server's int-width accumulator; explicitly
  casting its argument to BIGINT selects a 64-bit accumulator. Both ARITHABORT
  OFF and ANSI_WARNINGS OFF are required to turn an arithmetic failure into NULL;
  otherwise the error is catchable and honors XACT_ABORT. Integer AVG shares
  the checked accumulator, truncates the quotient toward zero, ignores NULLs,
  and retains int/bigint result width; COUNT_BIG always retains bigint metadata.
  DECIMAL/NUMERIC uses
  fixed-scale strings with scaled-BigInt casts and arithmetic, SQL Server
  operator precision/scale formulas (including the precision-38 reduction
  rules), half-away-from-zero rounding, and 8115/8134 errors.
- Mixed known types use the SQL Server precedence table before evaluation.
  Arithmetic, comparisons, BETWEEN, IN, simple and result CASE, set operations,
  multi-row VALUES, and DML/MERGE target assignments share that coercion path.
  Declared columns, variables, procedure parameters, and RPC TYPE_INFO all
  participate; invalid conversions preserve 245/241/8114/8169/8115 and
  incompatible pairs raise 206/402 instead of inheriting SQLite affinity.
- String boundary functions use dedicated UDFs where SQLite differs:
  SUBSTRING starts before one by shortening the returned prefix, negative
  LEFT/RIGHT/SUBSTRING lengths raise 536, negative REPLICATE/SPACE counts
  return NULL, and QUOTENAME accepts the documented delimiter pairs, doubles
  closing delimiters, and returns NULL for input longer than 128 characters.
  Their result descriptors follow SQL Server width rules: literal
  SUBSTRING/LEFT/RIGHT/SPACE counts narrow widths, REPLICATE multiplies and caps
  them at 8,000 bytes, REPLACE/TRANSLATE/STRING_AGG expose their family maximum,
  and STUFF accounts for removed and replacement widths.
- Under every currently supported non-SC collation, LEN, UNICODE, NCHAR,
  SUBSTRING, LEFT, RIGHT, STUFF, and REVERSE count or manipulate UTF-16 code
  units. Supplementary characters therefore count as two; NCHAR accepts one
  0-65535 unit; and boundary results may contain an unpaired surrogate. A future
  implemented `_SC` collation must switch these operations to code points.
- LIKE uses the effective or default SQL collation for literals, columns,
  variables, parameters, and computed expressions. Its matcher implements `%`,
  `_`, `[abc]`, `[a-c]`, `[^...]`, literal `[`, and ESCAPE; invalid ranges and
  malformed classes miss, while a multi-character ESCAPE raises 506.
- Character declarations default an omitted width to 1; CAST/CONVERT default
  it to 30. Explicit char/varchar/nchar/nvarchar conversions truncate and
  fixed-width families pad, while assignment into table storage rejects
  encoded overflow with error 2628. ISNULL retains its first argument's
  family and width; COALESCE follows character precedence and widens.
- SET NOCOUNT takes effect at statement execution time: ON suppresses the
  affected-row value in TDS DONE-family tokens but does not change execution or
  `@@ROWCOUNT`. A nested procedure, trigger, or dynamic batch inherits the
  caller's setting and restores it on exit; changes within that scope govern
  each completion produced there.
- Built-in system procedures use the same EXEC/RPC path as user procedures.
  Argument binding accepts positional, named, and DEFAULT values and dispatches
  the final name component case-insensitively. The implemented administration
  surface is `sp_help`, `sp_helptext`, `sp_columns`, `sp_tables`, `sp_who`,
  `sp_helpdb`, `sp_spaceused`, and `sp_rename`. Metadata procedures return
  explicitly typed SQL Server/ODBC schemas instead of relying on SQLite
  inference. `sp_rename` does not rewrite module text or dependent references,
  and function renames remain unsupported because runtime function registration
  cannot be changed atomically with SQLite schema and catalog state.
- Computed column grammar is `name AS expression [PERSISTED [NOT NULL]]` with
  no declared type. mssqlite infers the result from referenced columns, casts,
  numeric precision/scale, and supported scalar expressions; PERSISTED maps to
  a STORED SQLite generated column and the default maps to VIRTUAL. Direct
  INSERT/UPDATE raises 271 and nondeterministic generated definitions raise
  4936. Generated columns may be indexed normally.
- Supported COLLATE names are `SQL_Latin1_General_CP1_CI_AS` and the
  `Latin1_General_100_{CI|CS}_{AS|AI}` plus `Latin1_General_100_BIN2` matrix.
  Column declarations govern predicates, ORDER BY, unique constraints and
  indexes; expression COLLATE has explicit precedence. CI folds Unicode case,
  AI removes canonical combining marks, AS retains accents, and BIN2 uses the
  unmodified text key. Unknown names raise 448 and conflicting implicit
  collations raise 468.
- Missing COLLATE clauses are coercible-default
  `SQL_Latin1_General_CP1_CI_AS`. Predicates, joins, IN/BETWEEN, ordering,
  grouping, DISTINCT, set operators, and uniqueness compare a shared key that
  removes trailing U+0020 from both operands before applying Unicode case and
  accent sensitivity. Other Unicode space characters remain significant.
  LIKE is deliberately separate: a trailing blank in the pattern is
  significant, while trailing source blanks may match a shorter pattern.
  UPDATE/DELETE targets carry runtime type and collation metadata so their
  predicates use the same rule. Text foreign keys compare the referenced
  column's key for child validation and every referential action.
- CREATE [OR ALTER] PROC[EDURE] owns the rest of the batch as its body
  (MSSQL requires it to be alone in a batch); `parse()` patches the
  statement's `definition` with the trimmed batch source for
  sys.sql_modules. Parameters accept optional parens, defaults,
  OUT/OUTPUT and READONLY.
- CREATE/ALTER/CREATE OR ALTER TRIGGER also owns the rest of its batch.
  The AST retains the table target, AFTER/FOR or INSTEAD OF timing, ordered
  INSERT/UPDATE/DELETE event list, WITH options, NOT FOR REPLICATION, and body;
  DROP TRIGGER supports IF EXISTS and multiple names. Runtime transition
  tables are statement-level and read-only. Direct recursion is suppressed;
  nested triggers otherwise share the 32-level procedure/function limit.
- Named DECLARE CURSOR accepts LOCAL/GLOBAL, FORWARD_ONLY/SCROLL,
  STATIC/KEYSET/DYNAMIC/FAST_FORWARD, READ_ONLY/SCROLL_LOCKS/OPTIMISTIC,
  TYPE_WARNING and INSENSITIVE options plus optional FOR UPDATE metadata.
  OPEN materializes a read-only static snapshot for every declared type;
  FETCH supports NEXT/PRIOR/FIRST/LAST/ABSOLUTE/RELATIVE, either returning one
  row or assigning an equal-width INTO list, and updates session-global
  `@@FETCH_STATUS` (0 or -1; -2 cannot occur for snapshots). Plain,
  FORWARD_ONLY, and FAST_FORWARD cursors allow NEXT only; DYNAMIC rejects
  ABSOLUTE. LOCAL cursors clean up at batch/procedure/trigger scope exit,
  while GLOBAL (the default) persists until DEALLOCATE. Cursor variables,
  positioned UPDATE/DELETE, and live KEYSET/DYNAMIC behavior remain deferred.
- CREATE DATABASE, DROP DATABASE [IF EXISTS], ALTER DATABASE ... MODIFY NAME,
  and ALTER DATABASE ... SET READ_ONLY/READ_WRITE have dedicated AST nodes.
  USE switches database-owned storage and catalogs rather than changing only a
  label. Three-part object names retain the database component for attachment
  resolution; four-part linked-server names remain unsupported.
- CREATE/ALTER/DROP SEQUENCE parse integer types, START/RESTART, signed
  INCREMENT, MINVALUE/MAXVALUE (and NO forms), CYCLE and CACHE options in any
  order. NEXT VALUE FOR is a scalar AST node and uses a database-scoped generator;
  values persist across restart and remain consumed after rollback. Ascending
  sequences default to the type minimum, descending to the type maximum, and a
  cycle wraps to the configured/type minimum or maximum rather than START.
  Tinyint/smallint/int/bigint and decimal/numeric scale 0 (precision <= 18) are
  supported. OVER ordering, SQL Server's context restrictions, duplicate
  same-sequence coalescing within one result row, and sp_sequence_get_range are
  deferred; CACHE is retained in metadata but every completed statement flushes.
- ROWVERSION and its deprecated TIMESTAMP synonym declare the single automatic
  version column allowed per table. It takes no length, DEFAULT, IDENTITY,
  COLLATE, or ROWGUIDCOL clause. INSERT may omit it or name
  it with DEFAULT; explicit values raise 273, and any UPDATE assignment raises
  272. Every inserted or updated row receives a new database-wide big-endian
  binary(8), including no-op updates; nullable declarations still auto-generate
  values but expose varbinary(8) metadata. Values remain consumed after rollback,
  survive restart, span tables/table variables/sessions, and `@@DBTS` returns
  the latest allocated value without advancing it.
- TOP parses `PERCENT` and `WITH TIES` (`top.withTies`); UPDATE/DELETE
  accept `TOP (expr)` only, per MSSQL.
- OUTPUT clause (`Ast.Output`) sits between the column list / SET list /
  target and the source / FROM / WHERE. Items reuse the select-item shape
  minus variable assignment; `OUTPUT` being a reserved word is what stops
  the preceding expression (last SET value, INSERT column list) from
  swallowing it. INSERT/DELETE (and inserted-only UPDATE) transpile to
  SQLite `RETURNING` with the pseudo-table qualifier stripped; UPDATE
  reading `deleted.` values is engine-interpreted via a temp-table
  snapshot joined to the post-update rows. Divergences: an unaliased
  `deleted.x, inserted.x` pair collapses to one result key (duplicate
  column names — known engine-wide limitation, alias them), and
  `UPDATE … FROM` combined with `OUTPUT deleted.` is rejected.
- `Ast.TableSource` has a first-class `values` form shared by ordinary FROM,
  joins/APPLY and MERGE USING. The parser requires its table alias and retains
  the optional column-alias list plus raw rows. Engine resolution rejects
  unnamed, duplicate, mismatched and unequal-width columns with
  8155/8156/8158/8159/10709, resolves variables, and records the common
  SQL-precedence type and nullability for every column. Transpilation coerces
  the rows and wraps SQLite's native VALUES source in a stable named SELECT.
- MERGE parses in `parse/dml.ts`: USING accepts a table, `(SELECT …)` or
  the shared `(VALUES …)` source. `USING` had to
  join the reserved-word set or it parses as the target's alias. The
  parser requires MERGE's semicolon and reports 10713/15 when it is
  absent. Before snapshot construction, the engine rejects repeated actions
  with 10714/15 and a second MATCHED / BY SOURCE arm after an unconditional
  first arm with 5324/16. The same table can still be target and source (the
  snapshot makes it safe); multi-source matches for one target row raise
  8672. MERGE OUTPUT supports `$action` (lexed as a
  plain word — a leading `$` may start a word token), `inserted.` /
  `deleted.` items and stars, and `OUTPUT … INTO`; unlike SQL Server,
  source columns in MERGE OUTPUT are rejected (the row images are
  assembled after the arms apply, when source pairing is gone).
- `DECLARE @t TABLE (...)` reuses CREATE TABLE column/constraint members but
  requires the table variable to be the only declaration in that DECLARE.
  Object-position variables parse only in SELECT/INSERT/UPDATE/DELETE. The
  engine gives each declaration a unique SQLite temp backing table and
  scopes it to the declaring batch or procedure; nested procedures and
  `sp_executesql` cannot see a caller's table variables. Backing tables are
  dropped on normal or exceptional scope exit.
- FROM table sources recognize function calls with aliases and positional
  column aliases. Implemented built-ins are `STRING_SPLIT(string, separator
  [, enable_ordinal])`, default/explicit-schema `OPENJSON(json [, path])
  [WITH (...)]`, and `GENERATE_SERIES(start, stop [, step])`. STRING_SPLIT
  requires constant 0/1/NULL for `enable_ordinal`, returns no rows for NULL
  or empty input, preserves empty interior tokens, and only promises source
  position through its bigint `ordinal` column. OPENJSON evaluates BIN2-like
  lax/strict root and WITH-column paths, retains exact AS JSON fragments, and
  reports SQL Server's distinct missing/wrong-kind/malformed error states.
- CROSS/OUTER APPLY parse as left-associative join nodes without ON. The
  transpiler supports correlated STRING_SPLIT, OPENJSON, GENERATE_SERIES,
  VALUES, and arbitrary derived SELECT sources. Derived sources retain
  zero/one/many-row, aggregate, predicate, TOP/ORDER, nested-alias, and star
  semantics through the bounded typed row-packing lowering.
- PIVOT/UNPIVOT parse as postfix table transforms with mandatory aliases.
  PIVOT supports SUM/AVG/MIN/MAX/COUNT over a value column and requires a
  statically known source schema; listed values become conditional aggregate
  columns while every other input column remains a grouping key. UNPIVOT
  expands listed columns in order, omits NULLs, preserves generated metadata,
  and rejects duplicate names or incompatible known input types.
- GROUP BY represents expression tuples, ROLLUP units, CUBE units, explicit
  GROUPING SETS, and `()` independently in the AST. ROLLUP expands from the
  full list to the empty prefix; CUBE uses all combinations; top-level items
  combine by Cartesian product; explicit duplicate sets are not deduplicated.
  GROUPING(expr) is valid for a grouped expression and returns tinyint 0 for
  an active key or 1 for a subtotal placeholder.
- FOR JSON PATH/AUTO is a SELECT-tail AST option. ROOT accepts an optional
  string (default `root`); INCLUDE_NULL_VALUES and WITHOUT_ARRAY_WRAPPER are
  flags and duplicate options are rejected. PATH dotted aliases create
  nested properties. AUTO requires FROM; current execution supports one
  source or a root plus one joined child alias.
- FOR XML parses PATH/RAW/AUTO/EXPLICIT plus ROOT, ELEMENTS
  [ABSENT|XSINIL], BINARY BASE64, TYPE, XMLDATA, and XMLSCHEMA. Execution
  supports PATH and RAW: aliases may target attributes, nested elements,
  text()/data(), or wildcard inline content; NULLs are omitted unless XSINIL
  applies. WITH XMLNAMESPACES parses default and prefixed declarations.
  AUTO/EXPLICIT and schema directives raise specific compatibility errors.
- CREATE/ALTER/CREATE OR ALTER FUNCTION parses typed/defaulted parameters and
  either a scalar RETURNS type with BEGIN/END statements or an inline
  `RETURNS TABLE AS RETURN (SELECT ...)` body. Scalar execution allows local
  scalar variables, SET/assignment SELECT, control flow, RETURN, defaults and
  recursion but rejects side-effecting statements with error 443. Inline TVF
  arguments (including DEFAULT) substitute structurally into the stored query.
- `INSERT BULK table (column type, ...) [WITH (...)]` is the wire-protocol
  setup statement generated by BCP/SqlBulkCopy. It is intentionally recognized
  before the general T-SQL parser by `engine/prepareBulkLoad`, because execution
  continues in a following TDS packet type 7 stream rather than in the SQL
  batch. This is distinct from the user-facing `BULK INSERT ... FROM file`
  statement, which remains outside the server's filesystem-free scope.

### Not yet implemented (raise clean errors)

WAITFOR, GOTO, BULK INSERT ... FROM file, source columns in MERGE OUTPUT,
COLLATE as expression operator,
AT TIME ZONE.

`ALTER TABLE ... ALTER COLUMN` accepts declared type arguments, optional
COLLATE, and explicit/omitted nullability (omitted means NULL). Character
changes without COLLATE reset to the database default. The engine permits the
SQL Server-compatible indexed variable-length widening case and otherwise
rejects incompatible PK/index/FK/CHECK/DEFAULT/computed dependencies with
4922 before rebuilding and converting the stored column.

CROSS/OUTER APPLY retain left-to-right lateral dependencies in the source AST.
The resolved derived source carries projection metadata so arbitrary SELECT or
VALUES right sides can preserve aliases, stars, nullability, and wire types.
Derived execution supports predicates, aggregates, TOP/ORDER, nesting, and
zero/one/many rows; a non-table APPLY source that cannot be lowered raises the
specific compatibility error 40000 rather than becoming parser error 102.

### Compatibility audit findings

The live TDS audit at commit `bcad53b` found additional semantic gaps tracked
in [`todo/`](../../../todo). Unique constraints and explicit unique
indexes now treat repeated NULL-containing tuples as duplicates, preserving
collation keys and reporting 2627/2601 by origin. SELECT INTO now derives exact
expression/source types, nullability, collation, and eligible identity before
row execution. IDENTITY allocation findings from that
audit are implemented with database-owned counters, custom signed definitions,
rollback gaps, session IDENTITY_INSERT, and trigger-aware scope. It also
confirmed general APPLY lowering; strict OPENJSON paths, VALUES-derived tables,
and the audited MERGE terminator and arm validation rules are now implemented.
The remaining result-metadata, completion-token, and runtime error-stream
differences are indexed by [TODO.md](../../../TODO.md). Treat those individual
briefs as the executable scope and ground-truth checklist.

Result inference preserves integer nullability through catalog and scalar
projections: proven non-null tinyint/smallint/int/bigint results use fixed TDS
integer families, nullable results retain INTN, `@@TRANCOUNT` is non-null int,
and `XACT_STATE()` advertises nullable smallint width.
