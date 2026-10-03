# T-SQL Built-in Functions

All functions return NULL for NULL input unless noted otherwise. "Det" = Deterministic.

## 1. Aggregate Functions

All aggregate functions ignore NULLs (except COUNT(*)). If all inputs NULL, result is NULL (COUNT returns 0).

### COUNT
```sql
COUNT({ [ALL|DISTINCT] expression | * })
```
- Return: int. COUNT_BIG returns bigint.
- COUNT(*): all rows including NULLs. COUNT(expr): non-NULL only. DISTINCT: unique non-NULL.
- Det: Yes (without OVER).

### SUM
```sql
SUM([ALL|DISTINCT] numeric_expression)
```
- Return: tinyint/smallint/int→int, bigint→bigint, decimal(p,s)→decimal(38,s), money→money, float/real→float.
- Can overflow return type.
- Det: Yes.

### AVG
```sql
AVG([ALL|DISTINCT] numeric_expression)
```
- Return: same as SUM except decimal→decimal(38,max(s,6)).
- Integer division for integer types (AVG of 1,2 → 1). Use CAST for decimal.
- Not bit.
- Det: Yes.

### MIN / MAX
```sql
MIN([ALL|DISTINCT] expression)
MAX([ALL|DISTINCT] expression)
```
- Input: numeric, char, varchar, nchar, nvarchar, uniqueidentifier, datetime. Not bit.
- Return: same type. Character: collation order.
- Det: Yes.

### STRING_AGG
```sql
STRING_AGG(expression, separator) [WITHIN GROUP (ORDER BY ...)]
```
- Return: nvarchar(max) or varchar(8000) based on input.
- WITHIN GROUP ORDER BY controls concatenation order.
- Ignores NULLs. All NULL → returns NULL.
- Det: No.

### STDEV / VAR
```sql
STDEV([ALL|DISTINCT] expression)
VAR([ALL|DISTINCT] expression)
```
- Return: float.
- Requires >= 2 non-NULL values; otherwise NULL.
- Det: Yes (without OVER).

### COUNT_BIG
```sql
COUNT_BIG({ [ALL|DISTINCT] expression | * })
```
- Identical to COUNT but returns bigint.

### CHECKSUM_AGG
```sql
CHECKSUM_AGG([ALL|DISTINCT] int_expression)
```
- Return: int. Order-independent checksum. Det: Yes.

### GROUPING / GROUPING_ID
```sql
GROUPING(column)        -- Returns 1 if super-aggregate row, 0 otherwise
GROUPING_ID(col1, ...)  -- Bitmap integer: GROUPING(a)*4 + GROUPING(b)*2 + GROUPING(c)*1
```
- Det: Yes.

## 2. Ranking / Window Functions

All require OVER clause. All nondeterministic.

### ROW_NUMBER
```sql
ROW_NUMBER() OVER ([PARTITION BY ...] ORDER BY ...)
```
- Return: bigint. Sequential 1..N per partition.

### RANK
```sql
RANK() OVER ([PARTITION BY ...] ORDER BY ...)
```
- Return: bigint. Ties get same rank. Gaps after ties (1,2,2,4).

### DENSE_RANK
```sql
DENSE_RANK() OVER ([PARTITION BY ...] ORDER BY ...)
```
- Return: bigint. No gaps (1,2,2,3).

### NTILE
```sql
NTILE(integer_expression) OVER ([PARTITION BY ...] ORDER BY ...)
```
- Return: bigint. Distributes rows into N groups. Larger groups come first.

### LAG / LEAD
```sql
LAG(expr [, offset] [, default]) [IGNORE NULLS | RESPECT NULLS]
    OVER ([PARTITION BY ...] ORDER BY ...)
LEAD(expr [, offset] [, default]) [IGNORE NULLS | RESPECT NULLS]
    OVER ([PARTITION BY ...] ORDER BY ...)
```
- Return: type of expr. offset default = 1, default default = NULL.
- LAG looks back, LEAD looks forward.
- IGNORE NULLS: skip NULLs when looking.

### FIRST_VALUE / LAST_VALUE
```sql
FIRST_VALUE(expr [IGNORE NULLS | RESPECT NULLS])
    OVER ([PARTITION BY ...] ORDER BY ... [ROWS|RANGE ...])
LAST_VALUE(expr [IGNORE NULLS | RESPECT NULLS])
    OVER ([PARTITION BY ...] ORDER BY ... [ROWS|RANGE ...])
```
- **LAST_VALUE gotcha:** Default frame `RANGE UNBOUNDED PRECEDING AND CURRENT ROW` returns current row value. Use `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` for true last.

### PERCENT_RANK / CUME_DIST
```sql
PERCENT_RANK() OVER ([PARTITION BY ...] ORDER BY ...)
-- = (RANK() - 1) / (total_rows - 1). First row = 0.

CUME_DIST() OVER ([PARTITION BY ...] ORDER BY ...)
-- = (rows with value <= current) / total. Last row = 1.0.
```
- Return: float(53).

### PERCENTILE_CONT / PERCENTILE_DISC
```sql
PERCENTILE_CONT(numeric_literal)
    WITHIN GROUP (ORDER BY expr) OVER ([PARTITION BY ...])
PERCENTILE_DISC(numeric_literal)
    WITHIN GROUP (ORDER BY expr) OVER ([PARTITION BY ...])
```
- CONT: interpolates between values (returns float). DISC: returns actual value.
- Ignore NULLs.

## 3. String Functions

All deterministic unless noted.

| Function | Syntax | Return | Behavior |
|----------|--------|--------|----------|
| SUBSTRING | `SUBSTRING(expr, start, len)` | varchar/nvarchar/varbinary | 1-based. start < 1: begins at first char, len reduced. |
| LEN | `LEN(string)` | int/bigint | Excludes trailing spaces. Surrogate pairs = 1 char with SC collation. |
| DATALENGTH | `DATALENGTH(expr)` | int/bigint | Byte count. Includes trailing spaces. nvarchar = 2 bytes/char. |
| REPLACE | `REPLACE(str, pattern, repl)` | varchar/nvarchar | Case-sensitive per collation. Empty pattern → return str unchanged. |
| CONCAT | `CONCAT(arg1, arg2, ...)` | varchar/nvarchar | 2-254 args. **NULL → empty string** (never returns NULL). |
| UPPER | `UPPER(expr)` | varchar/nvarchar | Uppercase. |
| LOWER | `LOWER(expr)` | varchar/nvarchar | Lowercase. |
| TRIM | `TRIM([LEADING\|TRAILING\|BOTH] [chars FROM] str)` | varchar/nvarchar | Default: spaces from both ends. |
| LTRIM | `LTRIM(expr [, chars])` | varchar/nvarchar | Leading spaces (or chars). |
| RTRIM | `RTRIM(expr [, chars])` | varchar/nvarchar | Trailing spaces (or chars). |
| LEFT | `LEFT(expr, n)` | varchar/nvarchar | Leftmost n chars. Error if n < 0. |
| RIGHT | `RIGHT(expr, n)` | varchar/nvarchar | Rightmost n chars. Error if n < 0. |
| CHARINDEX | `CHARINDEX(find, search [, start])` | int/bigint | 1-based position. 0 if not found. Empty find → start. |
| PATINDEX | `PATINDEX('%pattern%', expr)` | int/bigint | 1-based. Pattern uses LIKE wildcards. 0 if not found. |
| REVERSE | `REVERSE(expr)` | varchar/nvarchar | Reverse UTF-16 units (characters under an SC collation). |
| REPLICATE | `REPLICATE(expr, n)` | same as input | Repeat n times. Truncates at 8000 unless max type. |
| SPACE | `SPACE(n)` | varchar | String of n spaces. NULL if n < 0. |
| STUFF | `STUFF(expr, start, len, repl)` | varchar/nvarchar/varbinary | Delete len chars at start, insert repl. NULL if start invalid. |
| CHAR | `CHAR(int)` | char(1) | ASCII 0-255. NULL if out of range. CHAR(0) = 0x00 byte. |
| NCHAR | `NCHAR(int)` | nchar(1) | Unicode code point. 0-65535 (or 1114111 with SC). |
| ASCII | `ASCII(char_expr)` | int | Code of leftmost character. |
| UNICODE | `UNICODE(nchar_expr)` | int | First UTF-16 unit under non-SC; first code point under SC. |
| STR | `STR(float [, len [, dec]])` | varchar | Right-justified. Default len=10, dec=0. `**` if overflow. |
| FORMAT | `FORMAT(value, fmt [, culture])` | nvarchar | .NET CLR formatting. Nondeterministic. Max 4000 chars. |

## 4. Mathematical Functions

All deterministic.

| Function | Syntax | Return | Behavior |
|----------|--------|--------|----------|
| ABS | `ABS(numeric)` | same category | Absolute value. Can overflow (ABS(-2147483648) overflows int). |
| CEILING | `CEILING(numeric)` | same category, scale=0 | Smallest integer >=. |
| FLOOR | `FLOOR(numeric)` | same category, scale=0 | Largest integer <=. |
| ROUND | `ROUND(numeric, len [, func])` | same type | len>0: decimal places. len<0: left of decimal. func=0: round (default). func≠0: truncate. Rounds half away from zero. |
| POWER | `POWER(base, y)` | matches input type | base^y. |
| SQRT | `SQRT(float)` | float | Square root. Negative → error. |
| SIGN | `SIGN(numeric)` | same category | +1, 0, or -1. |

## 5. Date/Time Functions

| Function | Syntax | Return | Det | Behavior |
|----------|--------|--------|-----|----------|
| GETDATE | `GETDATE()` | datetime | No | Current timestamp (~3.33ms precision). |
| SYSDATETIME | `SYSDATETIME()` | datetime2(7) | No | Current timestamp (100ns precision). |
| DATEADD | `DATEADD(part, num, date)` | same as date | Yes | Add num datepart units. Negative subtracts. Month overflow → last day of month. |
| DATEDIFF | `DATEDIFF(part, start, end)` | int | Yes | Count datepart boundaries crossed. Can overflow (use DATEDIFF_BIG for bigint). |
| DATEPART | `DATEPART(part, date)` | int | No | Integer value of datepart. weekday depends on DATEFIRST. |
| DATENAME | `DATENAME(part, date)` | nvarchar | No | String name (month/weekday) or number as string. Language-dependent. |
| DATEFROMPARTS | `DATEFROMPARTS(y, m, d)` | date | Yes | NULL if any argument is NULL; invalid ranges raise 289 state 1. |
| DATETIME2FROMPARTS | `DATETIME2FROMPARTS(y,m,d,h,mi,s,frac,prec)` | datetime2(prec) | Yes | All args required. |
| DATETIMEFROMPARTS | `DATETIMEFROMPARTS(y,m,d,h,mi,s,ms)` | datetime | Yes | NULL if any argument is NULL; invalid date/time or ms outside 0-999 raises 289 state 3. |

For `datetimeoffset`, DATEADD modifies local civil fields and preserves the
stored offset (it does not apply DST rules). DATEDIFF first accounts for the
offsets and counts boundaries between UTC-normalized instants. DATEADD accepts
microsecond and nanosecond parts; nanoseconds round to the 100ns storage tick.
`DATEPART(tzoffset, value)` returns signed minutes and DATENAME returns the
formatted `±HH:MM` offset.

### Datepart Keywords

| Datepart | Abbreviations |
|----------|---------------|
| year | yy, yyyy |
| quarter | qq, q |
| month | mm, m |
| dayofyear | dy, y |
| day | dd, d |
| week | wk, ww |
| weekday | dw |
| hour | hh |
| minute | mi, n |
| second | ss, s |
| millisecond | ms |
| microsecond | mcs |
| nanosecond | ns |
| tzoffset | tz |
| iso_week | isowk, isoww |

## 6. NULL Handling Functions

| Function | Syntax | Return | Behavior |
|----------|--------|--------|----------|
| ISNULL | `ISNULL(check, replacement)` | type of check | SQL Server-specific. Return type from check, not replacement. |
| COALESCE | `COALESCE(e1, e2, ...)` | highest precedence type | ANSI. First non-NULL. All NULL → NULL. May evaluate subqueries multiple times. |
| NULLIF | `NULLIF(e1, e2)` | type of e1 | Returns NULL if equal, e1 if not. |

**Key difference:** ISNULL return type = first arg type. COALESCE return type = highest precedence of ALL args.

## 7. Logical Functions

| Function | Syntax | Return | Behavior |
|----------|--------|--------|----------|
| IIF | `IIF(bool, true_val, false_val)` | highest precedence | UNKNOWN → false_val. At least one must be non-NULL. |
| CHOOSE | `CHOOSE(index, v1, v2, ...)` | highest precedence | 1-based. NULL/out-of-bounds → NULL. |

## 8. System / Session Functions

| Function | Return | Behavior |
|----------|--------|----------|
| `NEWID()` | uniqueidentifier | RFC 4122 GUID. Nondeterministic. |
| `DB_NAME([id])` | nvarchar(128) | Current or specified database name. |
| `OBJECT_ID('name' [, 'type'])` | int | Object ID. NULL if not found. Types: U=table, V=view, P=proc. |
| `OBJECT_NAME(id [, db_id])` | sysname | Object name from ID. |
| `SCHEMA_NAME([id])` | sysname | Schema name. |
| `TYPE_NAME(id)` | sysname | Type name. |
| `USER_NAME([id])` | nvarchar(128) | Current or specified user. |
| `CURRENT_USER` | sysname | Current database user. No parens. |
| `SESSION_USER` | nvarchar(128) | Session user. May differ after EXECUTE AS. |
| `SYSTEM_USER` | nvarchar(128) | Login name. Not affected by EXECUTE AS. |
| `@@ERROR` | int | Error number of last statement. Reset each statement. |
| `@@ROWCOUNT` | int | Rows affected by last statement. Reset each statement. |
| `@@IDENTITY` | numeric(38,0) | Last identity across ALL scopes. Affected by triggers. |
| `SCOPE_IDENTITY()` | numeric(38,0) | Last identity in CURRENT scope. Not affected by triggers. |
| `@@TRANCOUNT` | int | Transaction nesting level. |
| `@@FETCH_STATUS` | int | 0=ok, -1=fail, -2=missing, -9=not fetching. Global to connection. |
| `@@VERSION` | nvarchar | Server version string. |
| `@@SERVERNAME` | nvarchar | Server/instance name. |
| `XACT_STATE()` | int | 1=committable, -1=uncommittable, 0=no transaction. |

## 9. Error Functions (CATCH scope only)

All return NULL outside CATCH block. Nondeterministic.

| Function | Return | Value |
|----------|--------|-------|
| `ERROR_NUMBER()` | int | Error number |
| `ERROR_SEVERITY()` | int | Severity (0-25) |
| `ERROR_STATE()` | int | Error state |
| `ERROR_LINE()` | int | Line number |
| `ERROR_PROCEDURE()` | nvarchar(128) | Procedure/trigger name (NULL if outside proc) |
| `ERROR_MESSAGE()` | nvarchar(4000) | Full error message with substitutions |

## 10. JSON Functions

All deterministic.

| Function | Syntax | Return | Behavior |
|----------|--------|--------|----------|
| JSON_VALUE | `JSON_VALUE(json, path)` | nvarchar(4000) | Decoded/lexical scalar text; object/array is NULL in lax mode. Missing/wrong kind/over 4000 UTF-16 units raise in strict mode. |
| JSON_QUERY | `JSON_QUERY(json [, path])` | nvarchar(4000) | Original object/array fragment, including interior whitespace. Scalar is NULL in lax mode. Default path = `$`. |
| JSON_MODIFY | `JSON_MODIFY(json, path, val)` | nvarchar(max) | Update/insert. NULL val in lax = delete key. `append` for arrays. |
| ISJSON | `ISJSON(expr [, type])` | int | Default form accepts only object/array roots; NULL propagates. Optional types: VALUE, ARRAY, OBJECT, SCALAR. |
| OPENJSON | `OPENJSON(json [, path]) [WITH (...)]` | TABLE | Default: key/value/type. WITH: custom columns. Type values: 0=null,1=string,2=number,3=bool,4=array,5=object. |

### JSON Path Syntax
- `$` = root. `.key` = member. `[n]` = array element.
- `lax $.path` (default): NULL on error. `strict $.path`: error on missing.

## 11. Validation Functions

| Function | Syntax | Return | Behavior |
|----------|--------|--------|----------|
| ISNUMERIC | `ISNUMERIC(expr)` | int | 1 if parseable as numeric. Also 1 for +, -, currency symbols (design flaw). |
| ISDATE | `ISDATE(expr)` | int | 1 if valid date/time/datetime. 0 for datetime2. Depends on DATEFORMAT/LANGUAGE. |

## 12. Determinism Quick Reference

| Deterministic | Nondeterministic |
|---------------|-----------------|
| All aggregate (without OVER) | GETDATE, SYSDATETIME |
| All string functions | DATEPART, DATENAME |
| All math functions | FORMAT |
| CAST/CONVERT (usually) | All ranking functions |
| DATEFROMPARTS family | LAG, LEAD, FIRST_VALUE, LAST_VALUE |
| DATEADD, DATEDIFF | PERCENT_RANK, CUME_DIST |
| JSON functions | PERCENTILE_CONT/DISC |
| ISNULL, COALESCE, NULLIF | STRING_AGG |
| IIF, CHOOSE | NEWID |
| GROUPING, GROUPING_ID | @@ERROR, @@ROWCOUNT, etc. |
| DATALENGTH | ERROR_* functions |
| CHAR, NCHAR, ASCII, UNICODE | USER_NAME, CURRENT_USER |
