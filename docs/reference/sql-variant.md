# sql_variant and property functions

Rules derived from captures on SQL Server 17.0.5005 (harness corpus
`variant/*.sql`, `properties/*.sql`, `catalog/view-descriptors-variant.sql`).
Implementation: `src/core/types/variant.mbt` (conversion, comparison,
properties), `src/core/tds/variant.mbt` (wire), `src/core/bind/fn_variant.mbt`
(operator and built-in argument rules), `src/core/exec/fn_variant.mbt`
(SERVERPROPERTY), `src/core/session/properties.mbt`,
`src/core/session/sysviews_variant.mbt`, `src/core/session/simple_params.mbt`.

## Values and metadata

- A sql_variant value carries its base type with all parameters
  (`CAST('abc' AS sql_variant)` is varchar(3), `CAST(N'' AS nvarchar(3))` keeps
  nvarchar(3)). `Value::Variant(base value, base type)`; a NULL variant has no
  base type.
- COLMETADATA: type 0x62 with a 4-byte max length 8009 (sys.types and
  sys.columns say max_length 8016). CAST results are flags 33; ISNULL(variant,
  5) is non-null (32).
- Cannot be held: varchar(max), nvarchar(max), varbinary(max), xml,
  timestamp. CAST gives 529 state 1 ("Explicit conversion from data type
  varchar(max) to sql_variant is not allowed."); an assignment (INSERT,
  DECLARE, SET, SQL_VARIANT_PROPERTY's argument) gives 206 state 2 ("Operand
  type clash: varchar(max) is incompatible with sql_variant"). A variant in a
  variant is the same variant.
- DATALENGTH is the base value's storage size. Decimals use the coefficient
  magnitude, not the precision: 5/9/13/17 bytes for ≤ 2^32, 2^64, 2^96
  (DATALENGTH(CAST(12345678901234567890 AS decimal(38,0))) is 9, plain or in a
  variant).

## Conversions

- Into a variant: implicit from everything it can hold (it has the highest
  precedence, so mixed CASE/COALESCE/UNION/IN unify to sql_variant).
- Out of a variant: never implicit: 257 state 3 "Implicit conversion from
  data type sql_variant to int is not allowed. Use the CONVERT function to run
  this query." (assignment, PRINT, ISNULL(5, variant), arithmetic).
- CAST/CONVERT/TRY_CAST out of a variant convert the base value from its base
  type, styles included. A conversion the base type does not allow is 529
  **state 3** with the base type's name, even under TRY_CAST; at run time
  (after COLMETADATA) for non-constant operands, at compile time for constant
  ones. Value failures (245/8114) behave as for the base type and TRY_CAST
  turns them into NULL.
- A multi-row `VALUES` list unifies each column over its rows first, so the
  stored base type is the unified type: `VALUES (1, 1), (2, 2.5)` stores
  numeric(11,1) for both; `VALUES (1), ('abc')` fails with 245 (DONE CurCmd
  253); int with date fails with 206.
- Simple parameterization: an INSERT or UPDATE of a *permanent* table, run
  directly in a batch, with no variables, function calls or subqueries, turns
  string and binary literals into varchar(8000) / nvarchar(4000) /
  varbinary(8000) parameters. Variants stored from such literals report
  MaxLength 8000. Temp tables, procedures, `UPPER('abc')`, `(SELECT 'abc')` or
  `@x` keep the literal's length. Number literals keep their types (2.5 is
  numeric(2,1), 3000000000 numeric(10,0)).

## Comparison and ordering

Different type families order by family: date/time > approximate numeric >
exact numeric (incl. bit, money) > character > binary > uniqueidentifier, NULL
first ascending. Within a family the lower-precedence value converts to the
higher type: int 1 = decimal 1.0 = money 1, but int 1 < float 1e0 (different
families); a time compares as 1900-01-01 + time; datetimeoffset compares as UTC.
Character values first compare collation properties as integers (LCID,
version, comparison flags, sort id) and only then the strings under the
collation: `N'abc' COLLATE Latin1_General_CS_AS` < `N'ABC'` (SQL CI_AS), a
`_BIN` collation sorts after both. Same collation: `N'abc'` = `'ABC'`
(CI), trailing spaces ignored. Binary compares with zero padding
(0x01 = 0x0100). GROUP BY, DISTINCT, MIN/MAX, UNION use the same rules.

## Operators and built-ins (errors are compile time)

| Expression | Error |
| --- | --- |
| variant `+ - * /` integer/decimal/money/float | 257 to that type |
| variant `+ - * /` string, date, binary, guid, bit, NULL, variant | 402 "The data types sql_variant and date are incompatible in the add operator." (operands as written; `NULL` for a NULL literal) |
| variant `%` anything | 402 "... modulo operator." |
| variant `& | ^` other | 402 "... in the '&' operator."; two variants: 8117 "Operand data type sql_variant is invalid for '|' operator." |
| `-v`, `~v` | 8117 "... for minus operator." / "... for '~' operator." |
| `v LIKE p` | 8116 "Argument data type sql_variant is invalid for argument 1 of like function." |
| SUM, AVG, STDEV, STDEVP, VAR, VARP | 8117 "... for sum operator." (named after the function) |
| STRING_AGG | 8116 argument 1 or 2 |
| RAISERROR substitution argument | 2748 "Cannot specify sql_variant data type (parameter 4) as a substitution parameter." (whole batch) |
| COLLATE | 447 state 0 (bitsql still reports state 1) |

Built-ins either reject a variant with 8116 (LEN, UPPER, LTRIM, TRIM (named
"Trim"), SUBSTRING, REPLACE, PATINDEX, STUFF, FORMAT, HASHBYTES, JSON_VALUE,
ISNUMERIC, ISDATE, COMPRESS ("Compress"), EOMONTH arg 1, DATEADD arg 2,
DATETRUNC, ...) or report 257 to their parameter type (ABS/ROUND/POWER/trig →
float; SPACE/CHAR/LEFT arg 2/*FROMPARTS/OBJECT_NAME/DB_NAME → int;
DATEPART/YEAR/DATEDIFF/DATEADD arg 3 → datetime; QUOTENAME/OBJECT_ID/DB_ID →
nvarchar; CONCAT/CONCAT_WS/CHARINDEX arg 2 → varchar, nvarchar when another
argument is Unicode). They accept it: DATALENGTH, ISNULL, COALESCE, NULLIF,
IIF, CHOOSE (not the index), GREATEST, LEAST, MIN, MAX, COUNT,
SQL_VARIANT_PROPERTY. The full per-argument table is `variant_arg_rule` in
`bind/fn_variant.mbt` (one oracle probe per function and position).
CHECKSUM/BINARY_CHECKSUM accept a variant with an unknown hash: emulator error.

FOR JSON formats a variant as its base type (float `2.500000000000000e+000`,
real `1.5000000e+000`, money `3.0000`, binary base64).

## SQL_VARIANT_PROPERTY(v, name)

Result sql_variant (flags 33); names case-insensitive, not trimmed; unknown
name, NULL value or NULL name → NULL; a non-string name converts (2 → '2' →
NULL); one argument is 174.

| Property | Value |
| --- | --- |
| BaseType | sysname: `int`, `numeric`, `nvarchar`, ... |
| Precision | int: exact numerics as declared (money 19, smallmoney 10, bit 1), float 53, real 24, date 10, time(s) 8 (+s+1 when s > 0), datetime2(s) 19 (+s+1), datetimeoffset(s) 26 (+s+1), datetime 23, smalldatetime 16, others 0 |
| Scale | int: declared scale, datetime 3, others 0 |
| TotalBytes | int: 2 + property bytes + data bytes; property bytes: decimal 2, time family 1, binary 2, character 6 (the wire carries 7) |
| Collation | sysname of character base types, else NULL |
| MaxLength | int: declared maximum in bytes for character/binary (nvarchar(4000) 8000), decimal storage size of the value, fixed size otherwise |

## SERVERPROPERTY / DATABASEPROPERTYEX / CONNECTIONPROPERTY / SESSIONPROPERTY

All return sql_variant (flags 33); one/two arguments (174 otherwise); NULL or
unknown names → NULL; names case-insensitive, not trimmed.

- SERVERPROPERTY: values of the oracle image (Developer edition container):
  Edition `Enterprise Developer Edition (64-bit)`, EngineEdition 3,
  ProductVersion `17.0.5005.3`, ProductLevel `RTM`, ProductUpdateLevel `CU9`,
  ProductMajorVersion `17`, Collation, LCID 1033, SqlCharSetName `iso_1`,
  SqlSortOrderName `nocase_iso`, IsXTPSupported 1, HadrManagerStatus 1,
  InstanceName NULL, ... (exec/fn_variant.mbt). Strings are nvarchar(128)
  (ErrorLogFileName nvarchar(260)), flags int, SqlCharSet/SqlSortOrder tinyint,
  ResourceLastUpdateDateTime datetime. Differs from the oracle on purpose:
  MachineName, ServerName and ComputerNamePhysicalNetBIOS are the emulator's
  server name (`Config::server_name`, also @@SERVERNAME); ProcessID is 1;
  version fields follow `Config::version` (the revision, CU and KB stay
  those of 17.0.5005.3).
- DATABASEPROPERTYEX(db, p): same values for every database except Recovery
  (user databases and model FULL, master/tempdb/msdb SIMPLE) and
  IsFulltextEnabled (user databases and msdb 1). Version 998, Status
  `ONLINE`, Updateability `READ_WRITE`, UserAccess `MULTI_USER`, LastGoodCheckDbTime
  1900-01-01, IsClone/IsVerifiedClone/IsXTPSupported tinyint.
  IsReadCommittedSnapshotOn is *not* a DATABASEPROPERTYEX property (NULL; use
  sys.databases).
- CONNECTIONPROPERTY: net_transport/physical_net_transport `TCP`
  (nvarchar(40)), protocol_type `TSQL`, auth_scheme `SQL` (nvarchar(20)).
  local_net_address, local_tcp_port, client_net_address are emulator errors
  (the engine does not know addresses).
- SESSIONPROPERTY: ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, ARITHABORT,
  CONCAT_NULL_YIELDS_NULL, QUOTED_IDENTIFIER, NUMERIC_ROUNDABORT as int 0/1,
  following SET.

## Catalog views

- sys.identity_columns: sys.columns columns plus seed_value, increment_value,
  last_value (sql_variant of the column's type; last_value NULL until a value
  was generated, kept after DELETE).
- sys.sequences: sys.objects columns plus start_value, increment,
  minimum_value, maximum_value, current_value (the start value until first
  use), last_used_value (NULL until first use) as sql_variant of the
  sequence type; is_exhausted once the last value before the bound was handed
  out (no CYCLE); cache_size NULL unless `CACHE n`.
