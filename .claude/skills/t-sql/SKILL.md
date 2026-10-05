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

- 2026-10-05 (long literals, corpus `compat/long-literal-unify`): a string
  literal is nvarchar(max) above 4000 characters (`N''`), varchar(max) above
  8000 bytes, and a binary literal varbinary(max) above 8000 bytes; at the
  limit it is still sized (nvarchar(4000) / varchar(8000)). Unifying
  nvarchar(3) with nvarchar(max) is nvarchar(max), so VALUES / UNION / CASE
  keep 4060 characters; a sized varchar(5000) against nvarchar still caps at
  nvarchar(4000).
- 2026-10-05 (TOP/FETCH row counts, corpus `query/top-fetch-bigint`): a
  TOP/FETCH/OFFSET count is valid when its type is an integer type or when
  it is a *constant* of type `numeric` with scale 0, so `TOP 2147483648`,
  `TOP (1 * 2147483648)` and `CAST(2 AS numeric(5,0))` run while
  `CAST(2 AS decimal(5,0))`, a `numeric(19,0)` variable and `2147483648.0`
  are 1060 (OFFSET: 10743). The `decimal`/`numeric` name matters: binary
  arithmetic is numeric when either side is numeric (an int literal beside a
  decimal stays decimal), CASE/UNION ALL/COALESCE take the first branch's
  name. Constant FETCH ≤ 0 is batch-level 10744, constant negative OFFSET
  10742; at run time a FETCH variable of 0 returns no rows, negative is 127,
  NULL 1014; OFFSET NULL 10743. Counts above bigint fail at run time with
  8115 after COLMETADATA.
- 2026-10-05 (compat report 0.1.3, corpus `dml/compound-assignment`):
  `x op= e` (+= -= *= /= %= &= |= ^=) in UPDATE SET, MERGE UPDATE SET,
  SET @v and SELECT @v is exactly `x = x op e`: same result type, string
  `+=` concatenates, NULL propagates, 245 for `int += 'abc'` is a
  compile-time error (DONE 253), conversion back to the target type gives
  220/8115. A column assigned twice in one SET list (any qualification or
  case; also MERGE) is 264 for the whole batch, naming the catalog column.
  Bitwise `& | ^`: one operand must be bit/tinyint/smallint/int/bigint; the
  other may be an integer, binary/varbinary(max), char/nchar/varchar/
  nvarchar(max) or the NULL constant; the result is the integer operand's
  type (the higher one for two integers). Otherwise 402 naming both types
  (`NULL` for the constant, `varchar(max)` style), or 8117 naming the left
  type when neither side is a possible operand (decimal, float, money, date,
  guid, sql_variant, xml, text/ntext/image; `6.0`/`3000000000` are numeric).
  Integer overflow into tinyint is 220 **state 2** from int and smallint
  (CAST, assignment, column store), into smallint 220 state 1; bigint
  sources stay 8115. bitsql had int → tinyint as state 1 (corrected).
- 2026-10-04 (computed forward references, corpus
  `catalog/computed-forward-refs`): CREATE TABLE / ALTER TABLE ADD resolve
  every column type first (2715, 2705 come before a computed column's 207),
  then bind computed columns against all columns, whatever the declaration
  order; sys.columns and SELECT * keep declaration order. 1759 names any
  computed column of the statement used by another (forward, backward,
  itself). 2715's "Column, parameter, or variable #n" is the column's
  ordinal in the table (existing columns count under ALTER TABLE ADD; it was
  hard-coded #1 before). A column-level CHECK, REFERENCES, NULL or NOT NULL
  on a non-persisted computed column is 8183 for the whole batch (earlier
  statements do not run); a table-level CHECK naming it stays 1764 + 1750.
  Non-persisted computed columns are evaluated when read, not on INSERT
  (SQL Server's INSERT of a row whose computed value fails succeeds and the
  SELECT raises 245; bitsql still raises at INSERT, open in the roadmap).

- 2026-10-04 (filtered-index ALTER COLUMN): ALTER COLUMN dependents, each
  5074 (state 1, class 16) then 4922 state 9. A column named in a filtered
  index (or filtered statistics: "The statistics 'x' is dependent…")
  predicate cannot be altered at all, not even to the same type and
  nullability; an ordinary index allows growing a bounded varchar/nvarchar/
  varbinary and NOT NULL→NULL, but blocks NULL→NOT NULL (also for INCLUDE
  columns and UNIQUE constraints), shrinking, (max), precision and
  collation changes; a PRIMARY KEY also blocks NOT NULL→NULL. Computed
  columns block every ALTER COLUMN; CHECK blocks another type or
  collation but not a new length/precision; DEFAULT only another type;
  foreign keys (both sides) any type change incl. growing, never
  nullability. Order: defaults, computed columns, filter predicates,
  checks, then index/key columns in index order (a filtered index can be
  listed twice), then FKs; DROP COLUMN uses the same order. Unverified/not
  implemented: self-referencing FKs are listed among referencing FKs on
  DROP COLUMN in an order not yet understood (fk of another table first).
  Captures: corpus `catalog/alter-column-dependents`,
  `catalog/alter-column-filtered-index`.

- 2026-10-03 (FOR XML and xml, corpus `xml/`, docs/reference/xml.md):
  an untyped FOR XML subquery is nvarchar(max), with TYPE xml; no rows give
  NULL, rows without text `''`. Entities stay escaped in the STUFF idiom
  unless read back with `.value('.', 'nvarchar(max)')`. Whitespace-only
  values write their last character as `&#x20;`-style references, also in
  the text form. PATH merges consecutive columns with the same element
  path and skips NULL columns; RAW encodes invalid names as `_xHHHH_`, PATH
  rejects them (6850). The xml type is not comparable (305/402/421/5335),
  converts implicitly only from strings and binary (257 out to strings,
  206 otherwise), and its type errors are batch compile errors. XML parse
  errors (9400–9459, "line L, character C") end the batch and are NULL
  under TRY_CAST. value() converts the atomized string as nvarchar (245
  names nvarchar), requires a static singleton (2389) and rejects xml,
  sql_variant, text, image, timestamp and unknown types (9500); method
  names are case-sensitive (227); `name()` does not exist (2395); XQuery
  sum() of nothing is `0.0E0`.
- 2026-10-03 (RAISERROR, msduck raiserror-*): argument types must suit
  the specification: %d/%i/%u/%x/%o (also with `l`) take tinyint, smallint
  or int; `h` takes tinyint/smallint only; `I64` takes bigint only; %s/%ls
  take character types; `*` takes a non-NULL integer. A mismatch is 2786,
  a bad specification (also a trailing `%`) 2787; both report their own
  number but leave @@ERROR 50000 when the RAISERROR would have set it
  (severity > 10 or WITH SETERROR). Variables of decimal/float/date… types
  are compile error 2748 and more than 20 substitutions 2747 (the batch
  does not run); a decimal literal only fails the format check. A message id
  above 50000 gives 18054 and @@ERROR = the id. Severity > 18 without WITH
  LOG is 2754. RETURN with a value outside a procedure (also sp_executesql
  text) is compile error 178. `-@x` as an argument is 102 near '@x'.
- 2026-10-03 (OUTPUT clause, corpus `output/`, msduck `output-*`): the
  COLMETADATA of an OUTPUT without INTO is sent before the statement runs, so
  a run-time error (also in WHERE, SET, CHECK, a duplicate key or the OUTPUT
  expression itself) follows an empty or partial result set. UPDATE/DELETE/
  MERGE stream: rows processed before the failing row are sent; INSERT first
  evaluates its whole source (VALUES/SELECT errors send no rows), then
  streams per row. A duplicate key from `UPDATE SET id=10` over ids 10,20,30
  sends row 10 first; `SET id=30` sends nothing (keys applied one row at a
  time, though `id=id+10` succeeds). Scoping in UPDATE/DELETE OUTPUT: the
  target's alias or name is not visible (4104, `t.*` is 107 class 15), other
  FROM sources are, but only qualified (unqualified names are always 207);
  `s.*` expands; sources aliased `inserted`/`deleted` are shadowed by the
  pseudo-tables; `deleted.x` in INSERT is 4104. A qualifier naming a table
  without that column is 207, not 4104, also in subqueries, where an inner
  alias hides an outer one of the same name. An unaliased UPDATE/DELETE
  target binds to an unaliased FROM occurrence of its table, else to its
  only aliased occurrence; two aliased occurrences are 8154 "The table 'r' is
  ambiguous.". Numeric/decimal and bigint sources overflowing an integer type
  are 8115 state 2 "converting expression" (also CAST(2147483648 AS int));
  int → smallint/tinyint 220 state 1, smallint → tinyint 220 state 2; money
  → int 237/1, → smallint 237/2, → tinyint 232/11. Correction: bitsql used
  "converting numeric to data type int" state 1, which SQL Server never
  produced in captures.
- 2026-10-03 (updatable views/CTEs, corpus `views/`, `output/updatable-cte`):
  INSERT/UPDATE/DELETE through a view, CTE or derived table modify the one
  base table whose columns are written; the view WHERE restricts UPDATE/
  DELETE; INSERT fills the other base columns with defaults. Setting a
  derived column is 4406 (derived tables: 4421 "Derived table 'x' is not
  updatable because a column of the derived table is derived or
  constant."), checked before 4403 (aggregates, DISTINCT, GROUP BY; also for
  DELETE/INSERT); columns of two base tables (or DELETE through a join, or
  INSERT without a column list over a join) are 4405. OUTPUT images have
  the view's columns; `inserted.y` of an unmodified base table is 404 (also
  via `inserted.*`). WITH CHECK OPTION violations are 550 state 1 + 3621,
  per row, and a view over a CHECK OPTION view inherits the check. TOP in a
  CTE target is allowed by SQL Server (bitsql: 50100).
- 2026-10-03 (application locks, corpus `applock/`): sp_getapplock returns
  0 (granted), 1 (granted after waiting), -1 (timeout; no message), -999 with
  INFO 15625 "Option 'x' not recognized for '@LockMode' parameter." or 15626
  (Transaction owner without a transaction). Requests are counted: two
  acquisitions need two releases. sp_releaseapplock of a lock not held:
  ERROR 1223 and -999. APPLOCK_MODE returns 'NoLock' when not held and
  raises 3918 for the Transaction owner outside a transaction; APPLOCK_TEST
  is 1 for the session's own lock. Both procedures are T-SQL, so their
  statements show up as DONEINPROC tokens.
- 2026-10-03 (sql_variant, corpus `variant/`, `properties/`; rules in
  docs/reference/sql-variant.md): a variant keeps its full base type
  (varchar(3) for 'abc'); nothing converts implicitly *out* of a variant (257
  state 3, also PRINT, ISNULL(5, v), `v + 1`), max types/timestamp cannot go
  *in* (CAST 529, assignment 206). CAST out of a variant whose base type
  forbids the target is 529 **state 3** naming the base type, even under
  TRY_CAST, at run time unless the operand is constant. Comparison ranks
  families (date/time > float/real > exact numerics > strings > binary >
  guid), then converts within a family; strings compare collation LCID,
  version, flags, sort id first. Operators: numeric operand 257, others 402
  ("The data types sql_variant and NULL are incompatible in the add
  operator."), `%` always 402, bitwise 402 or 8117, unary 8117, LIKE 8116.
  Built-ins: 8116 or 257 per function and argument (table in
  bind/fn_variant.mbt). SUM/AVG/STDEV/VAR(P) of a variant are 8117 named after
  the function (bitsql used "stdev" for all four before). RAISERROR with a
  variant argument is 2748, a compile-time error for the whole batch, like
  PRINT of a variant (257).
- 2026-10-03: a multi-row `VALUES` list unifies each column's type over its
  rows before the target conversion (`VALUES (1), ('abc')` is 245 with DONE
  CurCmd 253; an int with a date is 206 per row). An untyped NULL row takes no
  part. Simple parameterization (INSERT/UPDATE of a permanent table, batch
  level, no variables/function calls/subqueries) types string and binary
  literals varchar(8000)/nvarchar(4000)/varbinary(8000) while number literals
  keep their types; only observable through sql_variant base types.
- 2026-10-03: DATALENGTH of a decimal is the storage size of its coefficient
  magnitude (5/9/13/17 bytes for < 2^32/2^64/2^96), not of its digits
  (12345678901234567890 as decimal(38,0) is 9; bitsql counted 13 before).
  FOR JSON prints money with 4 decimals (3.0000) and real with 8 significant
  digits (1.5000000e+000); bitsql printed 3.00 and 16 digits before.
- 2026-10-03 (properties): SERVERPROPERTY/DATABASEPROPERTYEX/
  CONNECTIONPROPERTY/SESSIONPROPERTY return sql_variant (flags 33), names
  case-insensitive but untrimmed, unknown → NULL, wrong arity 174. The oracle
  container is Developer edition: Edition 'Enterprise Developer Edition
  (64-bit)', EngineEdition 3, ProductVersion 17.0.5005.3 (CU9). DATABASEPROPERTYEX
  differs between user and system databases only in Recovery and
  IsFulltextEnabled; 'IsReadCommittedSnapshotOn' is not one of its properties
  (NULL). A sequence's ALTER ... RESTART warns 11729 from the values left
  *before* the restart.

- 2026-10-03 (sequences, corpus `sequence/`): NEXT VALUE FOR has the
  sequence's type and flags 0; an unqualified default start is the type's
  minimum (bigint: -9223372036854775808). CREATE/ALTER SEQUENCE send no DONE
  and warn 11729 (class 0) when the cache (default 50) exceeds the values
  left; RESTART WITH n also becomes the start value for a later bare RESTART.
  11728 (exhausted) aborts the batch and names the sequence unqualified;
  11703/11702/2714 quote the name as written (2714 state 8). DROP SEQUENCE is
  CurCmd 516. Repeated references to one sequence in a row share one value.
- 2026-10-03 (collations, corpus `collation/`, msduck bin2-*/collation-*):
  two different *implicit* collations meeting in `+`, CONCAT, CASE/IIF/
  COALESCE/CHOOSE or UNION ALL give a value with **no collation**. Using it
  in a comparison/LIKE/IN/string function/MIN-MAX is **4191** state 9
  "Cannot resolve collation conflict for <op> operation." (e.g. "for len
  operation"); returning it as a result column is **451** state 1 "... in
  <add|concat|CASE|UNION ALL> operator occurring in SELECT statement column
  n."; meeting directly in a sensitive op (`a = b`, REPLACE(a,b,..), UNION,
  INTERSECT, EXCEPT) is **468** state 9. INSERT…SELECT and `SELECT @v =`
  accept it; COLLATE repairs it. ISNULL takes the first argument's
  collation. `1 COLLATE x` is 447 **state 0**. Unicode → varchar applies
  Windows best fit per UTF-16 unit (452 mappings, captured), else '?'
  (surrogate pair → "??"); varchar compares by CP1252 bytes under BIN/BIN2,
  and under SQL_ collations varchar 'ß' ≠ 'ss'. Rules with evidence:
  docs/reference/result-metadata.md.
- 2026-10-03 (metadata, corpus `collation/expression-metadata`): `1+1` is
  IntN 33 (folding keeps nullability; the old "folds to non-null" guess was
  wrong). NULLIF types an integer-literal first argument by value (tinyint/
  smallint/int) and folds. Correction: the earlier note "integer literals
  next to a decimal are typed decimal(digits,0)" was only implemented for
  CHOOSE/GREATEST; it now covers arithmetic (`1.5*2` numeric(4,1)) and
  CASE/IIF/COALESCE branches too, and the type is *numeric*.
- 2026-10-03 (AT TIME ZONE, corpus `timezone/`, msduck `at-time-zone*`; full
  rules in docs/reference/at-time-zone.md): input must be datetime,
  smalldatetime, datetime2 or datetimeoffset (else 8116 arg 1; the zone must
  be a string, else 8116 arg 2); result datetimeoffset with the input scale,
  nullable. Zone names are the 141 Windows names, ASCII case-insensitive,
  U+0000 ignored, Kelvin sign = k, spaces significant; unknown → 9820 at run
  time (after COLMETADATA, NUL shown as '.'). Local input: repeated times take
  the earlier (daylight) offset, skipped ones are read in standard time and
  land after the change (02:30 → 03:30 -07:00); 9813 when the UTC instant
  leaves the range. datetimeoffset input whose local time overflows is
  silently clamped to the min/max UTC value at +00:00. SQL Server
  extrapolates each zone's first/last Windows yearly rule to years 1/9999
  and decides DST from the standard-time year with the daylight wall clock
  moved into that year, which creates real one-hour blips near new year
  (Central Brazilian 1904-01-01 03:00 UTC). `AT TIME ZONE` binds tighter than
  `+`.
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
  member missing from the root container validates the rest of the document
  and reports 13609 instead of NULL (corrected 2026-10-04: a miss inside a
  nested container or a step of the wrong kind validates nothing further).
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
  numeric(digits,0) by the binder (corrected from decimal): `2/2147483649` is numeric(12,11), but
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
- 2026-10-04 (procedures, corpus `proc/*`, msduck gaps-procedures,
  gaps-rpc-procedures): a procedure (or EXEC string) without RETURN <value>
  returns 10 - the highest severity of its *own* statements' errors, caught
  or not (11 → -1 … 16 → -6, 2627 → -4, 18 → -8; max, not first or last;
  bare RETURN after an error too); nested modules' errors and the EXEC
  statement's own errors (2812, 266, argument errors) do not count.
  sp_executesql returns the last @@ERROR. RETURN NULL is INFO 282 and 0.
  Errors split three ways inside modules: statement-level (continue),
  compile-time 208/137/syntax (end the module only: no RETURNSTATUS, `EXEC
  @r` leaves @r, @@ERROR = error, caller continues) and batch-aborting
  (245/241/8114 conversions, THROW, XACT_ABORT, 217: the whole batch, no
  DONEPROC). Batch-aborting conversion errors also roll back an open
  transaction (inside TRY: doom it, XACT_STATE() -1) without XACT_ABORT.
  EXEC errors: 2812 state 62 (continues), 201/8145/8143/8162 line 0
  (continue), argument conversion 8114 state 5 "Error converting data type
  varchar to int." (state 1 in procedure RPCs; overflow too: "int to
  tinyint"), 8144 line 0 and 119/179 end the batch; OUTPUT write-back
  overflow 8114 state 2 ends the batch. ERROR_PROCEDURE() names the
  procedure where the error happened (the called one for argument errors
  and 266; NULL for 2812 and dynamic SQL); ERROR_LINE() 0 for argument
  errors. Bare words are nvarchar arguments; DEFAULT without a default is
  201; a batch may start with a procedure name without EXEC. @@NESTLEVEL:
  procedure and EXEC string +1, sp_executesql text +2 (RPC too, and
  sp_prepexec); 217 when a 33rd level is entered. SET options set in a
  procedure, EXEC string or sp_executesql (also RPC) revert at its end.
  @@ROWCOUNT is 0 after a bare RETURN. CREATE PROCEDURE compiles its body:
  134 (duplicate parameter, redeclared variable), 137, 154 (USE), nested
  CREATE PROCEDURE 156 near the keyword; ALTER / CREATE OR ALTER PROCEDURE
  on a table 2010; DROP PROCEDURE of a table 3705, and a missing name in a
  list (3701) does not stop the other drops. Unverified: 266 under XACT_ABORT,
  argument-error order for mixed problems, ERROR_PROCEDURE() of 2812 inside
  a procedure, sp_executesql 8178 status rule (1, or 8178 when an argument
  named no parameter: two captures).
- 2026-10-04 (savepoints, msduck-runs `savepoint`): savepoints are a stack;
  ROLLBACK TRAN name matches the innermost savepoint under the database
  collation (CI: 'casename' finds CaseName, trailing spaces ignored, accents
  significant), removes it and later ones, else the outermost BEGIN TRAN
  name compared case-sensitively, else 6401 (state 2 for an empty name;
  statement-level, DONE 210). A NULL name variable means the whole
  transaction; variables are cut to 32 characters, literal names over 32 are
  103; non-character variables 3914 state 0. SAVE outside a transaction is
  628 state 0 and ends the batch (TRY completes the SAVE with 214).
  Savepoints survive an inner COMMIT; rolling back to one when the
  transaction is doomed is 3931. COMMIT/ROLLBACK errors complete with their
  own CurCmd (213/210). XACT_STATE() is 1 in a statement that also calls
  IDENT_CURRENT outside a transaction (captured, not implemented).

- 2026-10-03 (user-defined types, corpus `tabletypes/`): CREATE TYPE and
  DROP TYPE send no DONE of their own (a batch of them ends with DONE 253,
  like CREATE SCHEMA); CREATE/DROP SYNONYM likewise for CREATE, DROP SYNONYM
  is CurCmd 329. user_type_id starts at 257 per database; an alias type is
  nullable unless declared NOT NULL and gives its columns that default
  (sys.columns user_type_id = the alias). Errors: duplicate type 219 (name as
  written), missing 218, DROP of a type used by a column or parameter 3732
  naming the object, an alias of an alias 222, `FROM nvarchar(5000)` 2717
  state 2 then 225, unknown DECLARE type 2715 **state 3** + INFO 2724 (a
  table type as a column type is 2715 state 6), CAST to any non-system type
  243 ("Type X is not a defined system type.", state 2 when a user type of
  that name exists, else 1), a table variable used as a scalar 137 state 1
  class 16, duplicate column in a table type 2705 state 3 naming the type,
  two primary keys 8110 state 0 "'dbo.T3'" without 1750. Inline INDEX and key
  index ids are assigned in reverse order of definition after the clustered
  one (also CREATE TABLE).
- 2026-10-03 (table-valued parameters): a table-typed parameter must be
  READONLY (352, class 15) and READONLY needs a table type (346); a
  modification of one is the compile-time 10700 (CREATE PROCEDURE/FUNCTION
  fails; in sp_executesql text it ends the dynamic batch: ERROR,
  RETURNSTATUS 10700, no DONE; 352 likewise). `READONLY OUTPUT` and
  `READONLY = NULL` are 102. EXEC without the argument passes an empty
  table; a scalar argument is 206 "Operand type clash: int is incompatible
  with IdList" at line 0 followed by DONEPROC (error) without RETURNSTATUS.
  A TVP row violating the type's PK is 2627 at line 0 (random constraint
  name), INFO 3621 at line 1, DONE 253 and no RETURNSTATUS: the procedure
  never starts.
- 2026-10-03 (synonyms): resolved when used: a synonym of a missing object
  is created and fails later with 5313 "Synonym 'dbo.snone' refers to an
  invalid object." (SELECT and INSERT); `SELECT s.v FROM s` qualifies by the
  synonym name; CREATE SYNONYM over an existing name is 2714 **state 8**
  naming 'dbo.s' (CurCmd 170); DROP TABLE of a synonym and DROP SYNONYM of a
  table are 3705 ("Cannot use DROP TABLE with 'dbo.s' because 'dbo.s' is a
  synonym. Use DROP SYNONYM.").
- 2026-10-03 (sp_help family, corpus `sysprocs/`): sp_help, sp_helptext and
  sp_fkeys run with NOCOUNT ON (DONEINPROC 193 without counts), sp_columns,
  sp_tables, sp_pkeys and sp_who without (internal DONEINPROC 192/193
  sequences that depend on whether the object was found and on
  @table_owner). sp_help prints INFO 0 messages with a single space and
  internal line numbers between its result sets; 15472/15469/15470/15647
  name the object as passed. sp_helptext splits only at CR LF (a lone CR or
  LF stays in the line) and every 255 characters. sp_columns reports ODBC 2
  types (nvarchar(max) is `ntext` -10, datetime2 is -9) and an
  SS_DATA_TYPE that depends on nullability (int 56 / 38, bigint 63 / 108).
- 2026-10-03 (PIVOT/UNPIVOT, corpus `analytic/pivot*`, `unpivot`; rules in
  docs/reference/analytic.md): PIVOT groups by every source column it does
  not name and applies to the whole join tree written before it. The
  aggregate takes one bare column (anything else is a syntax error at the
  token); CHECKSUM_AGG is 406. IN values convert from nvarchar at compile
  time (8114 + 473), a value named like a grouping column is 265 + 8156,
  duplicates (case- and trailing-space-insensitive) 8156. Grouping columns
  keep their metadata, value columns are the aggregate type with flags 1, no
  8153 (except APPROX_COUNT_DISTINCT), no rows for empty input without
  grouping columns, and the row order without ORDER BY is plan-dependent
  once there are two grouping columns. UNPIVOT drops NULLs, emits IN-list
  order per row, `k` is nullable nvarchar(128) with the source column's own
  spelling, `v` needs identical types (8167) and takes their nullability.
- 2026-10-03 (analytic, corpus `analytic/percentile`, `window-frames`,
  `string-agg-checks`, `approx-checksum-agg`, `generate-series`,
  `tablesample`): PERCENTILE_CONT interpolates at rn = 1 + p(n-1) as
  (c-rn)v[f] + (rn-f)v[c] in double (float, flags 1), PERCENTILE_DISC
  returns the first value with i/n >= p in the key's type (NOT NULL for a NOT
  NULL key); errors 8726/8727/10751-10754/10758/402/5308/5309. The
  percentile may be any column-free expression (variables, RAND(),
  `(SELECT .5)`), evaluated once per call even over no rows (msduck-runs
  percentile-* captures, 2026-10-03 import: 580 of 664 pass, the rest are
  literal/float-text edge cases). SQL Server has
  no RANGE offsets: 4194 is faithful; frame offsets are unsigned int literals
  (102 otherwise), 4193 states 1/4/5, 10752 state 3 (ranking, NTILE,
  PERCENT_RANK, CUME_DIST) or 1 (LAG/LEAD/percentiles), 10756 for PARTITION
  BY without ORDER BY, 102 near ROWS with an empty OVER. STRING_AGG's
  separator must be a string literal (also 'a'+'b'), NULL or variable (8733;
  a column separator used to abort bitsql), nvarchar separators need a
  unicode value (8116), DISTINCT is 102, OVER 4113 state 4, ROLLUP 8710,
  9829 state 0 (varchar) / 1 (nvarchar). CHECKSUM_AGG is XOR over int only.
  APPROX_COUNT_DISTINCT was exact up to 30 distinct values and drifts from
  31 (bitsql: 50151 above 30 and under ROLLUP, where SQL Server accumulates
  across groups). GENERATE_SERIES: same integer type for all arguments or
  5373 (+206 per argument), decimal/numeric widen but do not mix, 8116 state
  = argument position, zero step 4199 (state 1 constant, 2 variable).
  TABLESAMPLE is deterministic only at 0/100 PERCENT (bitsql 50150
  otherwise); 476/479/482/497/494. Correction: `-2147483648` is an int
  literal (bitsql typed it numeric(10,0)).
- 2026-10-03 (JSON constructors and JSON_MODIFY, corpus `json2/`; rules in
  docs/reference/analytic.md): JSON_OBJECT/JSON_ARRAY return nvarchar(max)
  flags 33, default NULL ON NULL / ABSENT ON NULL, embed JSON-typed values
  (JSON_QUERY, JSON_OBJECT, JSON_ARRAY, FOR JSON with array wrapper) raw and
  escape everything else, NULL key 13638 at run time, `JSON_OBJECT('a', 1)`
  102 state 10. JSON_MODIFY edits the text in place: inserts go right before
  the closing bracket after existing whitespace, a lax NULL removes the
  member with its preceding comma (following comma for the first member),
  lax misses return the text unchanged, strict misses 13608 state 2; float
  values print with 16 digits; money/date/binary/guid/variant values are
  8116; a typed NULL path is 8116 state 8 at run time.
- 2026-10-03 (PARSE/TRY_PARSE, DATE_BUCKET, corpus `analytic/parse-*`,
  `date-bucket*`): PARSE follows .NET NumberStyles (Number for integers and
  decimal with thousands only after a digit and a trailing sign, Float,
  Currency), cultures en-US/en/en_US and `iv` (9818 for '', 'Invariant',
  NULL; bitsql 50171 for others), decimal targets report NumericN, two-digit
  years use the 2049 cutoff, clock/time-zone dependent text is 50172 in
  bitsql. DATE_BUCKET: origin 1900-01-01, floor division for fixed-length
  parts, DATEADD-style stepping for months, datetimeoffset in UTC keeping
  the offset, time wraps, result precision = max(date, origin), messages
  spell "Date_Bucket" (155 is a parse error).

- 2026-10-04 (foreign keys, msduck gaps-constraints, corpus
  `constraints/`): referential actions fire for every referenced row whose
  key a DELETE removes or an UPDATE changes, even when the value exists
  again afterwards (a CASE swap of keys 2 and 3 sets ON UPDATE SET NULL
  children to NULL; ON UPDATE CASCADE maps each old key to its own row's
  new key). SET NULL/SET DEFAULT/CASCADE UPDATE propagate as updates of the
  child (its computed columns, CHECKs over the key, unique keys and
  further actions apply), CASCADE DELETE as deletes. NO ACTION is checked
  against the statement's final state: `DELETE tree` of a self-referencing
  table succeeds, a NO ACTION key swap succeeds. A SET DEFAULT whose
  default has no parent row is 547 FOREIGN KEY naming the parent table with
  the parent statement's verb. Self-references say "FOREIGN KEY SAME TABLE"
  / "SAME TABLE REFERENCE"; multi-column keys name no column. NOCHECK
  foreign keys neither act nor check. UPDATE checks only CHECK/FOREIGN KEY
  constraints over the columns it sets (computed columns over them
  included), so a NOCHECK-violating row stays updatable elsewhere.
- 2026-10-05 (triggers and referential actions, corpus `triggers/cascade-*`,
  `instead-of-cascade-ddl`): child tables changed by CASCADE / SET NULL /
  SET DEFAULT fire their AFTER triggers after all cascades, before the
  statement's triggers, deepest first (reverse preorder, siblings by FK
  object_id); only tables with cascaded rows fire; UPDATE then DELETE
  triggers for a MERGE child, both with @@ROWCOUNT = all its cascaded rows.
  INSTEAD OF DELETE conflicts with ON DELETE CASCADE, INSTEAD OF UPDATE with
  any other action (ON DELETE SET NULL/DEFAULT, any ON UPDATE action),
  disabled FKs included: 2113 (state 1, "This is  because" with two spaces)
  at CREATE TRIGGER, 1787 + 1750 state 1 at ALTER TABLE ADD (ends the batch).
- 2026-10-04 (constraint definitions): 1785 (cycles or multiple cascade
  paths) is a table-level analysis: a DELETE reaches a child as a DELETE
  through ON DELETE CASCADE and as an UPDATE through ON DELETE SET
  NULL/DEFAULT; an UPDATE reaches it through any non-NO-ACTION ON UPDATE;
  reaching a table twice or the start table again fails, whatever columns
  the paths use. FK checks: 1778 different type (int/bigint, char/varchar,
  decimal/numeric), 1753 same type with another length/precision, 8139
  column counts (no 1750), 1761 SET NULL on a NOT NULL column, 1762 SET
  DEFAULT on a NOT NULL column without a default, 1764/1715/1765 computed
  referencing columns. 1750 follows with state 1 after 2714, 1505 and the
  FK errors, state 0 after 1779/1911/1769/1752/1781/8111/1919/1909 and a
  CHECK's 1764. Duplicate constraint names in one statement are 8168 (no
  1750); CONSTRAINT c10 inside CREATE TABLE c10 is 2714. CHECK/DEFAULT with
  a subquery 1046 (class 15), DEFAULT with a column 128 (class 15), a
  DEFAULT that cannot convert implicitly fails at CREATE (257 for
  SESSION_CONTEXT into nvarchar). Computed columns: another computed column
  1759, non-deterministic PERSISTED 4936. Messages print object names as
  written (3726, 4712, 1776, 1902, 1913, 8101, 8106), 3733 for a constraint
  of another table, 11415 for NOCHECK of a key/default.
- 2026-10-04 (indexes, msduck gaps-keys, corpus `constraints/`): filtered
  UNIQUE indexes hold only rows satisfying the filter (AND of column
  comparisons with constants and IS [NOT] NULL are emulated); IGNORE_DUP_KEY
  skips duplicate INSERT rows with INFO 3604 (UPDATE still 2601); options
  155 (unknown, class 15), 1916, 129 (class 15), 7999 (DROP_EXISTING without
  an index; with one the index keeps its id); 1909 duplicate key column,
  1919 max-type key, 8112 two clustered constraints in one statement, 8110
  state 0 without 1750; warnings 1945 (nonclustered key > 1700 bytes) and
  1944 (clustered > 900). DROP INDEX … WITH (options) on a nonclustered
  index is 3748 and ends the batch. ALTER COLUMN may widen a bounded
  varchar/nvarchar/varbinary under its indexes and keys.
- 2026-10-04 (IDENTITY_INSERT, msduck identity-insert-*): without a column
  list the identity column is never a target: a value for it is 8101
  (compile time, name as written) even while ON. 544 (OFF) and 545 (ON,
  identity omitted, also DEFAULT VALUES) are raised when the statement
  starts (CurCmd 195) before the source is evaluated, without 3621. DEFAULT
  or a NULL literal for the identity column is 339 at compile time;
  duplicate INSERT columns 264. The explicit value advances IDENT_CURRENT
  even when a later column of the row fails (conversion, CHECK, unique),
  not when the identity value itself fails to convert. While ON, the
  table's identity column reports COLMETADATA flags 24 (0x10|0x08) instead
  of 16. SET IDENTITY_INSERT inside a procedure, EXEC(@sql) or an
  sp_executesql RPC reverts when it ends, and SCOPE_IDENTITY() of the
  caller survives the call. A missing table is 1088 state 11.
- 2026-10-04 (XACT_STATE, msduck identity-insert-*, session-reset,
  gaps-merge): in autocommit, XACT_STATE() is 1 (with @@TRANCOUNT 0) when
  the same statement reads data or metadata — a FROM clause,
  IDENT_CURRENT, OBJECT_ID — and 0 otherwise. Unverified beyond those
  three shapes (bitsql scans the statement's tokens).
- 2026-10-04: SESSION_CONTEXT keys are set case-sensitively (N'LOCKED' is a
  key distinct from a read-only N'locked') but read case-insensitively
  (SESSION_CONTEXT(N'Tenant') finds 'tenant'); bitsql prefers the exact
  spelling (msduck session-property-context#068, gaps-computed#071).
- 2026-10-04 (functions round 2, corpus `functions2/`, docs/reference/
  format-parse.md): FORMAT and PARSE run .NET Framework culture data;
  bitsql reads it back from the oracle (`harness/gen/cultures.mjs` →
  exec/culture_data.mbt, 67 cultures, 148 known languages). Culture
  names: case-insensitive, `_` = `-`, unknown but well-formed names
  (`xx-XX`, `a-b`, `x-foo`) format like the invariant culture, malformed
  ones (`x`, `abcd`, `ab-12`, `'en-US '`, `German`) are 9818; the session
  language picks the default culture. Invalid format strings are .NET
  FormatExceptions (NULL): `B`, `Q`, `D`/`X` on non-integers, `R` on
  int/decimal, single letters other than the standard date formats,
  `ffffffff`, unescaped literals in time formats. Quirks: decimal/money
  custom formats starting with a quote print placeholders literally
  (`'a'0` → `a0`); a NULL format string means `G`; decimal `G` keeps its
  scale (`42.50`). Correction of the 2026-10-03 note: negative en-US
  currency is `($1.50)` (no longer unverified).
- 2026-10-04 (CONCAT, GREATEST/LEAST; msduck concat-legacy-family,
  concat-text-conversion, greatest-least): CONCAT/CONCAT_WS convert to
  nvarchar only when an argument (separator included) is nchar/nvarchar/
  ntext — xml and sql_variant do not count — and report the first
  unconvertible argument in order (xml/sql_variant 257 state 3, image
  206); binary reads as UTF-16LE there (ceil(n/2) characters, odd last
  byte padded) and in a Unicode TRANSLATE. GREATEST/LEAST rules are in
  docs/reference/result-metadata.md (first decimal/numeric argument's
  spelling, max types as 8000 bytes + 8152 state 10, NOT NULL only for
  digit-preserving conversions); this replaces the 2026-10-03
  "unverified" GREATEST nullability note.
- 2026-10-04 (ORDER BY, msduck order-token*): constant keys leave the
  ORDER token and the sort; hidden constant keys are 408, a bare variable
  1008 for the whole batch, a name matching two output columns 209, `-1`
  is a position (108 class 16). Window functions emit rows sorted by
  PARTITION BY then ORDER BY (a query without ORDER BY shows it); ties
  and PARTITION-only aggregates come out in plan order (not modelled).
- 2026-10-04 (literals and conversions, msduck percentile-*): a nonzero
  float literal below 2.2250738585072014e-308 reads as 0 with INFO 337
  (class 0) at parse time, before anything in the batch runs and also in
  dead branches; above the double range it is 168 (class 15) and nothing
  runs. String → float skips leading TAB/LF/VT/FF/CR/NBSP and Unicode
  spaces, stops at NUL ('0.5'+CHAR(0) is 0.5, CHAR(0)+'0.5' is 0) and
  allows only trailing spaces; '1e309' is 8115 (overflow), not 8114.
  Integers and decimals accept only spaces.
- 2026-10-04 (window and aggregate functions, functions2/offset-window,
  msduck statistical-*): IGNORE NULLS works on LAG/LEAD/FIRST_VALUE/
  LAST_VALUE; for LAG/LEAD it moves from the offset row further away to
  the first non-NULL value and returns NULL (not the default) when none
  exists. A NULL offset gives NULL, a negative one is 8730. STDEV/VAR are
  (Σx² − (Σx)²/n)/(n−1|n) in float, negative read as 0, infinite sums
  8115 — cancellation included (bit-identical on all captures). Float
  SUM/AVG overflow is 8115 even if later values would cancel it.
  Aggregate arity messages use the upper-case name ("The SUM function
  requires 1 argument(s)."); DISTINCT with OVER is 10759 class 15.
- 2026-10-04 (SWITCHOFFSET/TODATETIMEOFFSET, msduck offset-functions):
  zone text is not trimmed (' +01:30 ' is 9812); numeric zones convert
  like CAST(x AS int) (decimal truncates, money rounds); 9812 states 0/2
  for text, 1/3 for numbers, 9813 states 0/2 for range overflow.
- 2026-10-04 (math): SQL Server's SIN/COS/TAN/EXP/LOG/LOG10/ATN2 come
  from the Windows CRT and differ from fdlibm / correct rounding by 1 ulp
  on 2–20% of inputs (913-input dump; COS(1) is 0.5403023058681397 where
  the correctly rounded value ends in 98). Not emulated: no public
  algorithm is known to reproduce it bit for bit. COT is exactly
  COS(x)/SIN(x) of its own functions (0 differences), so bitsql computes
  it that way; SQRT and POWER matched on every input.
- 2026-10-04 (describe, session/describe.mbt):
  sys.dm_exec_describe_first_result_set and sp_describe_first_result_set
  describe the first row-returning SELECT from the binder; compile errors
  become rows (DMF: ordinal 0 + 11501/11529) or errors (procedure).
  Rules in docs/reference/result-metadata.md.
- 2026-10-04 (settings, corpus `settings/`, docs/reference/
  database-settings.md and date-strings.md "DATEFORMAT and LANGUAGE"):
  ALTER DATABASE completes with CurCmd 215; an unknown collation (448
  **state 3**), a bad COMPATIBILITY_LEVEL (15048) and `CURRENT` in
  tempdb/model/msdb (12104 state 2) are compile errors that end the batch
  (DONE 253), an unknown database is 5011 (class 14) + 5069 and a
  transaction 226 state 6 (both statement-level). Unknown SET option words
  are 102 **state 6**. The database collation types literals, variables,
  parameters and new columns (#temp: tempdb's) and, under CS/BIN, object
  names. SET DATEFORMAT: legacy parser keeps a lone 4-digit part as the
  year and swaps the others by the order (`2024-01-02` as datetime is Feb 1
  under dmy); the new parser always reads a leading 4-digit year as y-m-d
  and accepts nothing else under ydm. SET LANGUAGE also sets DATEFORMAT and
  DATEFIRST unless those were SET earlier in the same batch; INFO 5703 and
  error messages are localized (21 languages); inside EXEC it sends no
  ENVCHANGE/INFO and reverts. 2741/2740 are statement-level (CurCmd 249).
  LIKE ESCAPE errors (506) are state 2 when any operand is Unicode. 3952
  (snapshot not allowed) and 3906 (read-only) end the batch. `x = NULL` and
  `x IN (…, NULL)` never convert x to int (the NULL takes x's type).
- 2026-10-04 (UTF-8 collations, settings/utf8): only `…_SC_UTF8` and
  `…_BIN2_UTF8` exist for Latin1_General_100 (no `_SC` → 448). varchar(n)
  counts UTF-8 bytes (2628 shows the longest whole-character prefix), CAST
  of character data keeps the input collation (also outside UTF-8),
  COLLATE between code pages converts with best fit, UPPER/LOWER are
  varchar(min(8n, 8000)) and LEFT/RIGHT/SUBSTRING(…, k) varchar(min(8k, n)),
  `_SC` LEN/LEFT/RIGHT/SUBSTRING/REVERSE count a surrogate pair once.
  UPPER/LOWER map units by table version (v0: 1326 units, v100: 1764;
  msduck unicode-case, `scripts/gen-case-map.py`).


- 2026-10-04 (cursors, msduck-runs `cursor`, corpus `stmts/cursor-*`,
  rules in docs/reference/completions.md "Cursors"): the created type
  follows implicit conversions visible in sys.dm_exec_cursors
  ("TSQL | Dynamic | Optimistic | Global (0)"): STATIC/INSENSITIVE and any
  query with aggregates, GROUP BY, DISTINCT, UNION, window functions or no
  table are Snapshot (FAST_FORWARD never converts); KEYSET and SCROLL need a
  unique index on every table, else Snapshot; the default and DYNAMIC
  cursor over one table become Keyset with TOP, a select-list subquery or an
  ORDER BY no index provides (an index prefix extended by the clustered key,
  or a leading unique key, counts), joins stay Dynamic. Snapshot and
  Fast_Forward are Read Only. @@CURSOR_ROWS is n for Snapshot/Keyset, -1 for
  Dynamic/Fast_Forward, 0 once the last opened cursor is closed or
  deallocated; @@FETCH_STATUS starts at 0. Keyset rows deleted or re-keyed
  after OPEN fetch with -2, ROWSTAT 2 and blank values (NULL if nullable,
  else 0, n spaces, n zero bytes, 1900-01-01 for datetime, 0001-01-01 for
  date/datetime2, zero GUID); inserted rows never join. Dynamic cursors skip
  deleted rows and see rows inserted after the current position; ABSOLUTE
  is 16925. LOCAL cursors are visible only in their own batch/module (not to
  called procedures or sp_executesql), DEALLOCATE drops one reference (a
  cursor variable keeps a named cursor alive), CURSOR_STATUS('variable') is
  -2 without a cursor, dynamic cursors report 1 even when empty. 1048 names a
  fixed pair per conflict (not source order); 1049 is line 0. Correction:
  the 2026-10-03 roadmap note that DYNAMIC/KEYSET/FOR UPDATE must raise
  Emulator errors is superseded.
- 2026-10-04 (MERGE, msduck-runs merge-top-percent, gaps-merge, corpus
  `stmts/merge-hints`): MERGE TOP (p) PERCENT keeps ceil(n*p/100) action
  rows; outside 0..100 is 1031, NULL 1014 (class 15, batch ends with DONE
  253, also for variables); TOP (NULL) without PERCENT is 1060. Unknown DML
  target hints are 321 (hint lower-cased), NOLOCK/READUNCOMMITTED on a DML
  target 1065 (line 15), both whole-batch compile errors. MERGE compile
  errors 8102/271/109/110/213 complete with 253; an explicit identity value
  is 544 at CurCmd 279 without 3621; the NOT NULL message says "UPDATE
  fails." for INSERT actions too. 8672 fires at the second action touching a
  target row (two DELETEs delete once without error) after streaming the
  earlier OUTPUT rows, ends the batch, rollback ENVCHANGE after the ERROR.
  OUTPUT source columns are nullable when WHEN NOT MATCHED BY SOURCE exists.
- 2026-10-04 (triggers, msduck gaps-triggers, corpus
  `stmts/trigger-trancount`): inside INSERT/UPDATE/DELETE/MERGE, SELECT INTO
  and OUTPUT, @@TRANCOUNT reads max(@@TRANCOUNT, 1) + 1; inside a trigger it
  is 1 (XACT_STATE() 1). A trigger starts with @@ROWCOUNT = the firing
  statement's count (whole MERGE count for every action's trigger). After
  ROLLBACK in a trigger, inserted/deleted are empty and the trigger's later
  writes autocommit and survive 3609. An outer TRY catching a trigger error
  undoes the autocommit statement. INSTEAD OF INSERT sees 0 in the identity
  column and consumes no identity value; 217 at the nesting limit has no
  3621. MERGE with INSTEAD OF triggers: 5316 unless every present action has
  one; then they fire once per action (INSERT, UPDATE, DELETE), no AFTER
  triggers. Definition errors: 2714 state 2, 111 state 6, 2103, 2110, 2111,
  1034, 8197 state 6 (4 for a missing object). Standalone ENABLE/DISABLE
  TRIGGER sends no completion; 1088 state 21 (table) / 119 (trigger).
- 2026-10-04 (application locks, msduck gaps-applock, corpus
  `stmts/applock-validation`; token paths in `session/applock.mbt`):
  invalid or NULL @LockMode/@LockOwner is INFO 15625 ('(null)' for NULL) at
  lines 26/39 (sp_releaseapplock 20), then 246, 193, -999; values are
  case-insensitive with trailing blanks ignored. xp_userlock errors come as
  ERROR + DONEINPROC 224 (error bit), 193, -999, in the order 1227/2, 1224/5,
  1230, 1202 (get) and 1224, 1230, 3918/1, 1202, 1223 (release); under TRY
  ERROR_PROCEDURE() is 'sys.xp_userlock'. Each fixed database principal is
  its own lock space; resources truncate to 255 characters. Held modes
  combine: S+IX = SharedIntentExclusive, U+IX = UpdateIntentExclusive, X
  wins. APPLOCK_MODE/APPLOCK_TEST raise 1230/3, 1202, 1225/1-3, 1226, 3918/2
  at run time, 8116 at compile time for NULL literals or non-strings.
- 2026-10-04 (temp tables, msduck gaps-temp_tables, corpus `stmts/temp-*`):
  `db..#t` / `db.schema.#t` resolve to tempdb for any database name with
  INFO 2701 state 99 (database as written, line of the reference) once per
  reference at batch compile and again before a statement whose temp table
  did not exist at compile time. A missing temp table is 208 state 0 with
  the bare name. Two `CREATE TABLE #t` of one name in a batch are a
  compile-time 2714 state 1 at the second. Local temp tables of procedures
  and dynamic SQL (also sp_executesql RPCs) are dropped at module end, ##
  survive. tempdb catalog views list temp tables padded with `_` to 128
  characters plus 12 hex digits. Table variable DECLAREs are compile-time
  (loops keep rows, skipped branches still declare). 1087 in FROM is state 2.
- 2026-10-04 (WAITFOR, DBCC, msduck gaps-transactions, corpus
  `stmts/tx-*`): the WAITFOR argument is a string literal or variable only
  (else 102); literals are checked at compile time against
  `h:m[:s[.fff|:fff]]` with optional upper-case ` AM`/` PM` (148 for the
  batch, not catchable); variables mismatching are 241; (n)varchar(max) is
  always 241; int counts seconds; datetime uses its time of day; NULL returns
  at once; other types are 9815 (243 + error bit, batch continues); a past
  TIME waits until the next day. DBCC USEROPTIONS: nvarchar(128) `Set
  Option`, nvarchar(46) `Value` (flags 1), fixed row order (textsize,
  language, dateformat, datefirst, lock_timeout, ON flags, isolation level),
  CurCmd 230 + INFO 2528; errors 2532, 2583/3, 2526/3, 195/4.
- 2026-10-04 (rowversion and identity, msduck gaps-rowversion_identity,
  corpus `stmts/rowversion-identity-rules`): `timestamp` alone declares a
  timestamp column named timestamp; a second one is 2738 state 2, a default
  1755 + 1750; INSERT without a column list includes it and accepts only
  DEFAULT or NULL (273, compile time); UPDATE SET of it is 272; ALTER ADD
  rowversion stamps existing rows; UNION ALL of rowversion stays timestamp;
  MIN_ACTIVE_ROWVERSION() is NOT NULL. Identity: 2749 state 2 for other
  types, 8147 for IDENTITY NULL, 1754 + 1750 for a default; overflow is 8115
  "converting IDENTITY to data type X" + INFO 3606, ends the batch, rolls
  back (ERROR, ENVCHANGE, INFO) and leaves IDENT_CURRENT unchanged; an
  INSERT into a table without identity (even 0 rows, table variables,
  SELECT INTO) sets SCOPE_IDENTITY() and @@IDENTITY to NULL; 8106/8107 for
  IDENTITY_INSERT.

- 2026-10-04 (long tail round 4, corpus `tail/`, docs/reference/
  batch-checks.md): whole-batch compile errors (ERROR + DONE 253, nothing
  runs) for table hints (321 as written, 1047 isolation/granularity/
  UPDLOCK-XLOCK/NOLOCK conflicts, 10746, 367, 8171 state 2 NOEXPAND / 1
  IGNORE_*, 307/308, 8622 state 1 FORCESEEK without a leading-key predicate
  or with INDEX(0), state 2 INDEX(0) with another index), constant or
  non-integer TOP counts (127 negative, 1060 NULL or non-integer type even
  for a decimal variable, 1014 NULL percent, 1031 percent outside 0..100),
  window functions (4114 arity, 10755 LAG/LEAD, 10753 without OVER: state 3
  ranking/distribution, 1 offset/value functions; names as written), MERGE
  WHEN clauses (10714 repeated action, 5324 clause after an unconditional
  one), undeclared table variables (1087 state 2, also at CREATE
  PROCEDURE), unknown BACKUP options (155 state 1 / 2 with a value). Run-time
  TOP/percent errors and NTILE 4116 end the batch (no rollback; RPC: DONEPROC
  right after the ERROR); DML TOP adds 3621 after 127 only. Legacy `t
  (NOLOCK)` takes one hint, `t (INDEX(0))` is 1018, table variables take no
  hints (319; DML targets 156), 319 prints 'with' lower-case. Niladic
  functions with parentheses are 102 near the token after `(`.
- 2026-10-04 (statements): END CATCH sets @@ROWCOUNT 0 (also when CATCH did
  not run); COUNT(NULL) in UPDATE SET is 8117 before 157; BACKUP of a
  missing database is 911 (state 11, LOG 10) + 3013 at CurCmd 228/235, the
  batch continues, TRY catches 3013 only; a table variable is invisible to
  EXEC(), sp_executesql and procedures (1087) and takes no named
  constraints (156); UPDATE/DELETE FROM outer joins skip NULL-extended
  targets, APPLY in their FROM sees the target. EXEC sp_prepare in T-SQL
  compiles one SELECT (COLMETADATA + ORDER, DONEINPROC 193 count 0), else
  defers (status 8182) or fails with the error + 8180; @options 0 is 214
  state 3; sp_execute returns the last @@ERROR. A `PERSISTED NOT NULL`
  computed column keeps its expression's nullability on the wire; indexing a
  non-deterministic computed column is 2729. Columns through a view or
  inline function report as base columns (flags 8/9) unless computed.
  `WHERE 1=0` never runs its source; WHERE conjuncts over APPLY's left input
  filter before the applied side runs (no errors from removed rows). Still
  plan-dependent and not modelled: an uncorrelated aggregate subquery is
  evaluated even over zero outer rows (8153; aggregate-warning-boundaries
  #008), rows of earlier groups precede an aggregate's run-time error
  (json-aggregates#017).
- 2026-10-04 (session options, fork B; docs/reference/database-settings.md
  "Session SET options"): ANSI_NULLS OFF makes `=`/`<>`/`!=` two-valued only
  against a NULL literal or a bare variable/parameter; IN lists and simple
  CASE compare per item; subquery IN/ALL/ANY treat NULL = NULL. Modules keep
  their CREATE-time ANSI_NULLS / QUOTED_IDENTIFIER (SET inside a procedure
  has no effect and sends no DONE). QUOTED_IDENTIFIER applies at parse time.
  @@OPTIONS bits 8/16/32/64/128/256/4096/8192. FROM exposed names: 1013 two
  tables (later one named first), 1011 two correlation names, 1012 alias vs
  table, before 207, not catchable; views/inline functions that no longer
  bind give the inner error then 4413 (line 13 for a schema-qualified name).
  sp_refreshview 15165 at line 62. EXEC argument errors: 201 before
  8145/8143/8162. sp_set_session_context check order 16914/16903, 225,
  15666, 15600, 15664.
- 2026-10-04 (functions, fork C; docs/reference/hash-compress.md):
  STRING_ESCAPE trims the kind's trailing spaces, NULL literal kind is 8116
  state 1 at compile time, typed NULL 8116 state 8 at run time. STRING_SPLIT
  arity 313/8144 state 3, Unicode separator makes the value nvarchar,
  enable_ordinal is any constant (NULL = no ordinal), other values 4199,
  non-integers 8116, a variable 8748 for the whole batch. QUOTENAME: empty
  delimiter = '[', NUL first delimiter returns the input. HASHBYTES trims
  trailing blanks of the algorithm. CHECKSUM of decimals is |value| as a
  38-digit integer folded per 32-bit word (sign ignored); of Unicode text
  under version-0 Windows collations the primary sort keys with rotl3.
  DECLARE is compile-time (a variable declared in a skipped branch exists as
  NULL; a loop re-runs only the initializer). CREATE FUNCTION compiles its
  body (137), 102 state 31 for BEGIN in an inline / RETURN-first scalar
  body, 2010 between kinds (CurCmd 222), 3729 states 1/3 for functions used
  by computed columns/defaults/schema-bound modules, 4512 state 3, 4513
  state 2. 8169 (GUID) and 289 (*FROMPARTS) end the batch. SOUNDEX reads
  code page 1252 and skips upper-case H/W (compat >= 110). CONVERT of
  date/time types to binary: storage bytes, 8152 state 17 when cut.
- 2026-10-04 (json data type, corpus `json4/`, docs/reference/json.md
  "The json data type"): a json value is canonical text: object/array root
  only, no whitespace, first of duplicate members kept, strings re-escaped
  (`\u00XX` upper-case for control characters, `/` raw, lone surrogates →
  U+FFFD), numbers with an exponent or > 38 digits through float to
  decimal(38,10) (`1e2` → `100.0000000000`; 1007 state 5 / 3 when out of
  range), others kept as written. Malformed text is 13609 **state 9** with a
  **UTF-8 byte** position (string errors at the opening quote), nesting
  beyond 128 is 13645; both end the batch at run time and TRY_CAST makes
  them NULL (not 1007). Implicit conversions: character → json only; json →
  character 257, anything else ↔ json 206; json has the highest precedence
  (CASE/COALESCE/UNION ALL with strings give json). json → (n)varchar:
  13640 for an unmappable character (best fit applies), then 13639 when too
  short. Not comparable: 13636 state 1 (=, NULLIF, joins) / state 2 (ORDER
  BY, GROUP BY, window keys), 421, 5335, 402 against other types, MIN/MAX
  8117, COUNT(DISTINCT) 8117 state 2, CREATE INDEX 1978 state 3, PK 1919.
  JSON_QUERY/JSON_MODIFY of json return json; json documents report other
  error states (13608 state 5, OPENJSON 7 / WITH 8, 13623/13624 state 2).
  A json argument or RETURNING JSON makes JSON_OBJECT/JSON_ARRAY/the JSON
  aggregates return json (float overflow 8115 state 19 in constructors, 18
  in JSON_MODIFY, 1007 in aggregates); windowed aggregates stay nvarchar.
  `json(n)` is 2716 (declarations) / 291 (CAST); RETURNING json(n|max) is
  accepted. DATALENGTH is the binary size (emulator error).
- 2026-10-04 (named windows, tail5 fork B1, corpus `tail5/b1-named-window`,
  docs/reference/tail5-b1.md): `WINDOW w AS (…)` follows HAVING and comes
  before ORDER BY. `OVER w` / `OVER (w …)` may add elements but never
  repeat them (4123 state 2 in OVER, 5367 state 2 in definitions). Names
  are case-insensitive and local to their SELECT: subqueries cannot see
  them, the SELECT's ORDER BY can. Definitions may reference later ones.
  Errors stop the whole batch: 5362 (state 3 without a clause, 4 for a
  missing name, 7 inside a definition including a window naming itself),
  16211, 5365, 5364, 5366 (ranking functions state 3, offset and value
  functions state 2). `OVER (w)` is 102 near ')'. `WINDOW` is not reserved.
- 2026-10-04 (NEXT VALUE FOR OVER, fork B1, corpus
  `tail5/b1-next-value-over`): values follow the OVER order, not the
  query's ORDER BY; the same OVER shares one value per row; a different
  OVER, or OVER mixed with a plain reference, is 11727. 11716 PARTITION BY,
  11718 empty OVER, 11737 frame, 11717 UPDATE/MERGE/DEFAULT (1046 first for
  a subquery in a DEFAULT), 11720 WHERE/ORDER BY, 11739 TOP/OFFSET (plain
  form too), 11723 plain form in a query with ORDER BY. An exhausted
  sequence sends the rows numbered before it, then 11728. `OVER (ORDER BY
  SUM(n) OVER ())` kills the SQL Server session (596, severity 21).
- 2026-10-04 (parser error recovery, fork B1, corpus
  `tail5/b1-syntax-recovery`): SQL Server reports several syntax errors per
  batch. An error at `WITH` adds 319 at the same token (`UPDATE/INSERT/
  MERGE @t WITH (…)` give 156 then 319; `DELETE FROM @t WITH` 319 alone).
  Statements then restart at later tokens, and the next error is reported
  only after three tokens were accepted (yacc): `SELECT 1 x y; SELECT 2 a
  b` gives two 102s, `SELECT 1 x y; UPDATE` one. This closes the 2026-10-04
  open item "several syntax errors from one statement (156 + 319)".
- 2026-10-04 (8120/8121/8127, fork B1, corpus `tail5/b1-ungrouped-name`):
  the column is qualified by the FROM object name as written (schema
  included, brackets removed, original case), even when aliased; derived
  tables use their alias. A name ambiguous among FROM sources is 209 even
  when one copy is grouped.
- 2026-10-04 (READPAST, hints, sp_prepare; tail5 fork B2, corpus
  `tail5/b2-*`, docs/reference/tail5-b2.md): READPAST outside READ
  COMMITTED/REPEATABLE READ is 650 at run time, only when the table is read
  (after COLMETADATA; DONE 253 for DML and assignments); it ends the batch,
  rolls back the transaction, and TRY catches it. The isolation is the
  table hint, else the session level; SNAPSHOT fails, READ_COMMITTED_SNAPSHOT
  passes. UPDATE/DELETE/MERGE targets ignore a READ UNCOMMITTED session,
  UPDATE/DELETE pass a WHERE that is exactly clustered PK = constant or
  variable. READPAST on an INSERT target is 4102 for the batch. INDEX hints
  on views are INFO 4430 at compile time per reference, on DML targets
  1069. `t (a, b)` gives 207s then 215 (line 13 when schema-qualified);
  `t alias (NOLOCK, X)` 1018 or 102 near X. EXEC sp_prepare of DML,
  assignments, SET, PRINT, CREATE TABLE or BEGIN TRAN sends DONEINPROC with
  the statement's CurCmd (count 0 for DML and assignments); compile errors
  give the error + 8180; DECLARE and IF prepare deferred (8182). ALTER
  SCHEMA … TRANSFER (OBJECT::/TYPE::) keeps the object_id, moves
  constraints and triggers, sends no DONE; errors 15151, 15530, 33144, 2710
  at CurCmd 170.
- 2026-10-04 (untyped NULL, corpus `query/derived-untyped-null`,
  `query/union-untyped-null-tvf`): SQL Server's "NULL constant" (NULL,
  `(NULL)`, `-NULL`, `~NULL`, `NULL + NULL`, `ISNULL(NULL, NULL)`) keeps
  that status through derived tables, CTEs, VALUES (all rows NULL),
  DISTINCT, TOP, GROUP BY, outer joins and UNION/EXCEPT whose every branch
  is one: describe/SELECT INTO report int, yet it assigns to
  datetimeoffset/uniqueidentifier/xml, loses UNION precedence, and
  `s.o + N'x'`, `ISNULL(s.o, N'z')`, `s.o = N'abc'` treat it as untyped.
  Not through views, inline TVFs, SELECT INTO, `(SELECT NULL)`, and not
  for `CAST(NULL AS int)`, VALUES mixing NULL with 5, `NULL * 2` or `-s.o`
  (all int, 206 into datetimeoffset); `~s.o` and `+s.o` stay untyped.
  A bare `s.o` is not "the NULL constant" for CASE 8133, COALESCE 4127 or
  ORDER BY constants (ORDER token sent), but `ISNULL(s.o, NULL)` and
  `NULL + s.o` are; MIN/MAX/COUNT/SUM over it are 8117, STRING_AGG 8116.
  CONCAT counts the NULL keyword as length 0 but a bare `s.o` as
  varchar(1). bitsql: `ColumnRef.untyped_null`, references bind as
  `Lit(Null)` int (bind/expr.mbt `bind_column`).

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
- 2026-10-03 (date strings, harness/corpus/datestrings, ~3,600 captured
  cases; rules in docs/reference/date-strings.md): datetime/smalldatetime
  use a *legacy* parser, date/time/datetime2/datetimeoffset a *new* one, and
  they differ: legacy accepts the time anywhere (`10:11 1/2/2024`), mixed
  separators, 3-digit parts, at most 3 fraction digits, spaces only; new
  accepts TAB, 7+ fraction digits (rounded at the 8th), UTC offsets, 1/2/4-
  digit years only. Legacy errors split into 241 state 1 (syntax;
  smalldatetime 295 state 3) and 242 state 3 (invalid field, duplicated
  part, out of range — also for `13/1/2024`); the new parser always says 241.
  241 and 295 **abort the batch**, 242 does not. Two-digit years: 0–49 →
  20xx. ISDATE = CAST AS datetime succeeds. CONVERT styles for strings set
  the d/m/y order and the year width (<100 two digits, ≥100 four); 112 on
  the new parser rejects separated dates with 9807 state 0. Correction: the
  type-conversion.md row "datetime fractional > 3 digits → truncated" does
  not hold for strings (241), and the old test claiming `.12345678` fails
  for datetime2 was wrong (it rounds).
- 2026-10-04 (CONVERT styles, msduck gaps-conversion, corpus `conversion/`;
  rules in docs/reference/conversion-styles.md): every temporal type has a
  defined text for styles 0-14, 20-35, 100-115, 120, 121, 126, 127, 130, 131
  (26-35, undocumented, are other day/month/year orders: 26 is yyyy-dd-mm);
  other numbers are 281 state 1 (TRY_CONVERT: NULL). Date-only styles on time
  and 8/24/108 on date are 8114 state 5 ("Error converting data type time to
  varchar."), 14/114 on date 281. Undocumented style 115 is `hhmmss`. 126/127
  drop an all-zero fraction for every type. 130/131 are Hijri (Kuwaiti
  algorithm; before 622-07-18: 9814 state 0). Input styles: text styles reject
  separated numeric dates like 112 (new parser 9807), unknown numbers are
  9809 state 1 on the new parser and 112-like on the legacy one, 22/23/25 work
  only on the new parser, 131 (both parsers) / 130 (legacy) read Hijri
  `dd/mm/yyyy`. CONVERT with a variable style works per row (NULL style →
  NULL; varchar/bit/decimal style 8116). float styles: 1/2/3 = 8/16/17
  digits, 126 = 16 (real: 8), anything else = 0; money: anything but 1/2/126
  = 0. Correction: the type-conversion.md style table said float style 3 and
  unknown styles were invalid.
- 2026-10-04 (storage bytes, msduck concat-numeric-format): CONVERT(varbinary,
  x) of float/real is big-endian IEEE, of money/smallmoney the big-endian
  int64/int32 units, of decimal `p, s, 0, sign(1 = +), magnitude LE` in the
  fewest whole 4-byte groups. binary → float/real is 529 (not allowed), binary → money/
  decimal read these layouts back. Binary → character styles 1/2 cut to whole
  bytes; other styles 9809.
- 2026-10-04 (text/ntext/image, docs/reference/lob-types.md): conversions only
  between text/ntext and character types and between image and
  binary/varbinary/timestamp (+ from varchar); comparisons and `+` are 402,
  ORDER/GROUP BY 306 state 2, DISTINCT 421, UNION 5335, MIN/MAX/COUNT 8117,
  DECLARE 2739, index keys 1919; most string functions 8116 (TRIM and
  COMPRESS spell "Trim"/"Compress"), DATALENGTH/SUBSTRING/CHARINDEX/PATINDEX/
  CONCAT/ISNULL work. SUBSTRING(text, s, n) is varchar(n).
- 2026-10-04 (LIKE / PATINDEX / CHARINDEX, msduck like-patterns,
  charindex-patindex): LIKE compares characters and ranges under the
  collation (CI matches 'B' to [a-c], CI_AS does not match 'É' to [e], SQL CS
  varchar orders aAbB so [a-c] matches 'B'); `[]` and an unclosed `[` never
  match; a trailing escape character never matches; ESCAPE of length ≠ 1 is
  506; trailing value blanks are ignored only when both sides are non-Unicode.
  Ignorable code units (version-0 surrogates, NUL, soft hyphen) take no part
  in LIKE/PATINDEX matches but block CHARINDEX matches (CHARINDEX(N'ab',
  N'a'+NCHAR(0xAD)+N'b') = 0). `_SC` collations count a surrogate pair as one
  character in positions and `_`. A constant `x LIKE p` folds (CASE result
  NOT NULL), `NOT LIKE` does not. NCHAR/CHAR accept binary (NCHAR(0x00AD)).
- 2026-10-04 (COMPRESS/DECOMPRESS, CHECKSUM; docs/reference/hash-compress.md):
  COMPRESS is gzip with header 1F8B080000000000 0400 around zlib 1.3.1
  level-6 deflate (byte-exact); DECOMPRESS returns NULL for input cut inside
  header or data, 9826 for corruption, checks the trailer only when complete.
  CHECKSUM/BINARY_CHECKSUM fold per-argument values with rotl4/xor; typed
  NULL is 0x7FFFFFFF; per-type values in the reference. Correction: bitsql's
  BINARY_CHECKSUM folded all arguments into one stream (wrong for several
  arguments) and CHECKSUM hashed NULL as 0.
- 2026-10-04 (errors): COUNT(NULL)/COUNT_BIG(NULL) is 8117 for the whole batch
  (also under IF 1=0), but the statement's own 208/207 come first; SUM(NULL)
  is 8117 "for sum operator" and inner NULL aggregates win over 130. CASE
  whose results are all the NULL constant is 8133. A decimal literal with
  more than 38 digits is 1007 (class 15). NTILE takes tinyint..bigint only and
  a constant count < 1 or NULL is 4116 (class 15, also on empty input); a
  query column in its argument is 4195. ISJSON of a non-character type is
  8116. INFO 8153 precedes the DONE of every statement kind (DML, SET/DECLARE
  with a subquery) and follows a failing INSERT's 3621; it is dropped under
  SET ANSI_WARNINGS OFF and inside a caught TRY. The 529 message names
  `decimal` (unlike 8115, which says numeric).
- 2026-10-04 (built-ins): ROWCOUNT_BIG() is bigint NOT NULL; CURSOR_STATUS is
  smallint NOT NULL (-3 missing, local lookups see only LOCAL cursors, -1
  closed, 0/1 open without/with rows; 16902 state 42/43 for a bad source /
  NULL name); COLUMNS_UPDATED() is varbinary(4000): one bit per column_id - 1
  in ceil(n/8) bytes, empty for DELETE, NULL outside triggers.
- 2026-10-04 (JSON round 3, corpus `json3/`, rules in
  docs/reference/json.md): SQL Server 2025 parses `.*`, `[*]` and
  `[a to b]` (`[n to n]` = `[n]`; reversed 13660/1, `last` 13660/2, lists
  13660/5); multi-value paths validate whole candidate containers, a JSON
  null ends them with NULL even under strict, strict skips missing members
  inside them, strict ranges past the end are 13659. The path lexer allows
  whitespace around every token and uses 13607 states 14/22/21/15/16/17/20.
  13608/13609/13623/13624 states follow the document type (max vs not), and
  every JSON run-time error ends the batch (RPC: ERROR then DONEPROC).
  13606 is lazy (complete scalars/names inside 129 containers, containers
  opened there). ISJSON(x, VALUE|ARRAY|OBJECT|SCALAR) (155 parse error for
  other words, batch-level 1023 otherwise); JSON_PATH_EXISTS is 0 for any
  invalid document. FOR JSON AUTO nests by first-column order with
  consecutive collation-equal merging; 13600/13620 are batch compile errors.
  JSON_ARRAYAGG/JSON_OBJECTAGG: ABSENT/NULL defaults differ, WITHIN GROUP is
  ignored, unordered JSON aggregates follow the scope's ordered aggregate,
  OVER gives running values. The json type is on the wire as varchar(max)
  Latin1_General_100_BIN2_UTF8 (bitsql: not supported).

Source https://learn.microsoft.com/en-us/sql/t-sql/language-reference?view=sql-server-ver17
- 2026-10-04 (ORM suite, corpus `orm/`): an untyped NULL literal stores
  into any column or variable (`SET d = NULL` on datetime2/date/time/
  datetimeoffset/uniqueidentifier/xml/sql_variant); a typed source that
  does not convert implicitly is a compile-time error before any row:
  206 state 2 when CAST could not convert it either (`SET d = 1` on
  datetime2, also via an int variable), 257 when only CAST could.
  `SELECT DISTINCT` without ORDER BY comes out sorted on the select list
  for small inputs (one OR-ed seek per predicate can instead keep predicate
  order: plan-dependent). ALTER COLUMN under a DEFAULT constraint may change
  length, precision, scale and nullability of the same type, not the type
  or to/from (max) (5074 + 4922). USE inside EXEC()/sp_executesql lasts
  for that scope only and sends neither ENVCHANGE nor 5701; USE of a
  missing database (911) ends the batch. INSERT column lists accept up to
  four-part names and ignore every qualifier. `db..t` means the default
  schema. ODBCSCALE(type_id, scale) (undocumented, Prisma) converts both
  arguments to tinyint (220 state 2) and returns the scale for type ids
  40-43, 48, 52, 56, 58, 60, 61, 106, 108, 122, 127, else NULL.
  sp_addextendedproperty and friends: a NULL @name is a RAISERROR (15600
  class 15 line 22, batch runs on); every other failure (15600 states
  1/2/3/11, 15135 states 4/8/9/15, 15233, 15217) is class 16 at line 37
  (add) / 36 (update) / 28 (drop), ends the batch and rolls back the
  transaction; ERROR_PROCEDURE() is the procedure. The string 'default'
  passed to fn_listextendedproperty is a name, not DEFAULT.
- 2026-10-04 (corpus `backup/*`, msduck gaps-backup): BACKUP/RESTORE
  errors are statement-level: the specific error(s) then 3013 "<BACKUP
  DATABASE|BACKUP LOG|RESTORE DATABASE|RESTORE HEADERONLY|RESTORE
  FILELIST|VERIFY DATABASE> is terminating abnormally." (VERIFYONLY's text
  is VERIFY DATABASE, FILELISTONLY's RESTORE FILELIST); TRY catches only the
  3013. CurCmd 228 BACKUP DATABASE, 235 LOG, 229 RESTORE DATABASE, 250
  HEADERONLY, 376 FILELISTONLY, 377 VERIFYONLY (result sets DONE 230). 3021
  state 0 in a user transaction (also before 911; HEADERONLY runs inside
  one), 3147 state 3 tempdb, 3201 state 2 missing file, 3287 bad FILE for
  DATABASE but 4038 (state 1, HEADERONLY 3) for the other kinds, 3154 state
  4 before 3234 state 2, 3159 for a FULL-recovery same-family target
  without REPLACE, 3102 (own session, dynamic USE included) / 3101 (others'
  own database only), 1834 + 3156 (state 4) per file then 3119. Device
  paths and MOVE logical names compare case-insensitively. RESTORE sends
  BEGIN/COMMIT transaction ENVCHANGEs before its 3014; each 4035/3211 info
  closes an internal DONE. A restored database keeps the source's object
  ids. The 5701 "Changed database context" info of a USE carries the USE
  statement's line (bitsql said line 1 until 2026-10-04).

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
COLLATE as expression operator.
(AT TIME ZONE is implemented: docs/reference/at-time-zone.md.)

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

- 2026-10-04 (compatibility report round 2, corpus `constraints/`):
  `DEFAULT NULL` / `(NULL)` / `(-NULL)` is the untyped NULL constant (any
  column type, xml too); typed defaults are checked at CREATE/ALTER like
  an assignment (206 no conversion, 257 explicit only: varbinary→date).
  Binary converts *explicitly* to date/time/datetime2/datetimeoffset (bad
  images are 241, not 529). A column definition may carry `FOREIGN KEY
  (x) REFERENCES …`: it binds column x (any column, even one declared
  later); two columns are 8140 "More than one key specified in column
  level FOREIGN KEY constraint, table '<name as written>'". A column CHECK
  naming another (known) column is 8141 "… table '<bare name>'" + 1750,
  two column CHECKs on one column 8148; all three are batch compile errors
  (line of the statement), except an ALTER of a table created in the same
  batch (deferred compile, raised when it runs); an unknown name is 207
  first. PERSISTED (4936) determinism: CONVERT between character data and
  any date/time type is deterministic only with style 20, 21 or ≥ 100
  except 106/107/109/113 (CAST = no style; implicit conversions and date
  functions over strings count); CAST out of sql_variant, every `@@`
  global, metadata/security/session/error functions (OBJECT_ID, DB_NAME,
  USER_ID, SERVERPROPERTY, XACT_STATE…), FORMAT, DATENAME, ISDATE, PARSE,
  COMPRESS, AT TIME ZONE and DATEPART week/weekday are nondeterministic;
  RAND(seed), DECOMPRESS, HASHBYTES, JSON functions, DATEPART iso_week are
  deterministic. NEWSEQUENTIALID outside a DEFAULT is 302.

- 2026-10-04 (corpus `conversion/datetime-arithmetic`): `datetime` ± x
  converts x (int, decimal, money, float, bit, binary, character data,
  smalldatetime, datetime) to datetime and adds day counts: `@d + 1.5` is
  +36 h, `@d + N'12:00'` +12 h, `@d + @d` 2140-…, the fraction rounds to
  1/300 s (`+ 0.0000001` day is .010). The result is smalldatetime only
  when no datetime takes part (rounded to the minute). Out of range is
  8115 "…converting expression to data type datetime" at run time. `*`/`/`
  are 257 (datetime to int), `%` 402, datetime with date/time/datetime2/
  datetimeoffset/uniqueidentifier 402 "The data types datetime and date
  are incompatible in the add operator". date/time/datetime2/dto with a
  number is 206 with the temporal type first ("date is incompatible with
  int", both operand orders). `CURRENT_DATE` (2025) is a non-nullable
  date; `CURRENT_DATE()` is 102 near ')'.

- 2026-10-04 (msduck default-collation, openjson-isnull; dumps in
  `src/core/types/collation_weights_data.mbt`): under the version-0 tables
  (SQL_Latin1_General_CP1_*, Latin1_General_*) 21,229 BMP code units are
  fully ignorable (NUL, U+0640, U+200D–U+200F, U+2060…, BOM, U+FFFE/F,
  surrogates, unknown code points) but not the soft hyphen; version 100
  ignores the soft hyphen and ZWNJ but not the BOM or surrogates. varchar
  under SQL_ collations ignores nothing, not even CHAR(0). Accent order is
  the table's (á < à < ä < ā), not code point order. ORDER BY on varchar
  under an SQL_ collation uses the SQL sort order: '-a' sorts before '_'
  (string sort; word sort only for nvarchar). OPENJSON's `value` has a
  coercible-default collation: COALESCE(value, key) is key's BIN2 (no
  451). CASE/COALESCE with constant conditions fold to the column even
  for nvarchar(max) (flags 9/1). ISNULL(@n nvarchar(10), x nvarchar(4000)
  NOT NULL) is nullable (the replacement may be cut). There is no
  Latin1_General_140_* (448). A column `COLLATE bad` is 448 state 2 for
  the whole batch; `int COLLATE …` is 447 "Expression type int is invalid
  for COLLATE clause."

- 2026-10-04 (session/prebind.mbt): SQL Server compiles the whole batch
  first: `DECLARE @d date = '…'; SELECT @d + 1` returns only 206 (no DONE
  for the DECLARE), also when the bad statement sits in an IF branch that
  never runs or in a TRY block (not catchable), and after a statement on a
  missing table (deferred name resolution skips only that statement).
  `DECLARE @n nvarchar(10) = @variant` is a batch-level 257. Run-time
  errors (8134, 245) still come after earlier results.

- 2026-10-05 (compat report 0.1.3 #4): `WITH … SELECT @v = … FROM cte` is
  ordinary T-SQL (one or more CTEs, recursive, in triggers). `SELECT @v = …
  FOR JSON|XML` is compile error 6819 state 3 "The FOR XML clause is not
  allowed in a ASSIGNMENT statement." for both (whole batch, reported on
  the WITH line). `WITH r AS (…) SELECT 7` / `SELECT @k = 7` (no FROM,
  WHERE, TOP, DISTINCT, ORDER BY, subquery, aggregate) is 422 state 4
  "Common table expression defined but not used." for the whole batch, on
  the SELECT's line; an unused CTE next to a FROM, WHERE 1 = 1, a
  subquery or COUNT(*) is fine (`session/precheck.mbt select_shape_error`).
- 2026-10-05: lock escalation on 17.0.5005.3 fires when one statement holds
  ~6250 locks on a table counting KEY **and PAGE** locks (6200-row UPDATE
  of an `(int PK, int)` table: 6200 KEY X + 14 PAGE IX, no escalation;
  6240 rows: OBJECT X), not at the documented 5000. On a 32-CPU host the
  escalated lock shows as 32 OBJECT X rows in sys.dm_tran_locks (lock
  partitioning). Details and why bitsql does not escalate: decisions.md
  2026-10-05 "lock grants per (table, session)".
