# T-SQL Data Types

## 1. Type Precedence (highest to lowest)

When an operator combines expressions of different types, the lower-precedence type is implicitly converted to the higher. If conversion is not supported, an error is raised.

```
 1. user-defined data types (highest)
 2. json
 3. sql_variant
 4. xml
 5. datetimeoffset
 6. datetime2
 7. datetime
 8. smalldatetime
 9. date
10. time
11. float
12. real
13. decimal
14. money
15. smallmoney
16. bigint
17. int
18. smallint
19. tinyint
20. bit
21. ntext
22. text
23. image
24. timestamp
25. uniqueidentifier
26. nvarchar (including nvarchar(max))
27. nchar
28. varchar (including varchar(max))
29. char
30. varbinary (including varbinary(max))
31. binary (lowest)
```

## 2. Exact Numeric Types

### Integer Types

| Type | Storage | Range |
|------|---------|-------|
| tinyint | 1 byte | 0 to 255 |
| smallint | 2 bytes | -32,768 to 32,767 |
| int | 4 bytes | -2,147,483,648 to 2,147,483,647 |
| bigint | 8 bytes | -2^63 to 2^63-1 |

**Rules:**
- `int` is the primary integer type.
- Constants > 2,147,483,647 are converted to `decimal`, NOT `bigint`.
- Functions return `bigint` only if the parameter is already `bigint`.
- Arithmetic on integer constants first converts to `decimal` with minimal precision.
- float to integer: **truncated** (not rounded).

### decimal / numeric (synonyms)

**Syntax:** `decimal[(p[,s])]` or `numeric[(p[,s])]`
- p (precision): 1 to 38. Default = 18.
- s (scale): 0 to p. Default = 0.

**Storage:**

| Precision | Storage |
|-----------|---------|
| 1-9 | 5 bytes |
| 10-19 | 9 bytes |
| 20-28 | 13 bytes |
| 29-38 | 17 bytes |

**Range:** -10^38+1 to 10^38-1.

**Arithmetic result precision/scale (critical for implementation):**

| Operation | Result Precision | Result Scale |
|-----------|-----------------|-------------|
| e1 + e2 | max(s1,s2) + max(p1-s1, p2-s2) + 1 | max(s1, s2) |
| e1 - e2 | max(s1,s2) + max(p1-s1, p2-s2) + 1 | max(s1, s2) |
| e1 * e2 | p1 + p2 + 1 | s1 + s2 |
| e1 / e2 | p1 - s1 + s2 + max(6, s1 + p2 + 1) | max(6, s1 + p2 + 1) |
| e1 % e2 | min(p1-s1, p2-s2) + max(s1,s2) | max(s1, s2) |

**Maximum cap:** 38. When result precision > 38, scale is reduced to prevent truncating the integral part. Additional scale reduction for multiplication/division:
1. integral < 32: scale = min(scale, 38 - integral). Rounded.
2. integral >= 32, scale < 6: unchanged; overflow possible.
3. integral >= 32, scale >= 6: scale set to 6; result is decimal(38,6).

### bit

- Storage: optimized — 1 byte per 8 bit columns in a table.
- Values: 1, 0, or NULL.
- "TRUE"/"FALSE" strings convert to 1/0.
- Any nonzero value converts to 1.

### money / smallmoney

| Type | Storage | Range |
|------|---------|-------|
| money | 8 bytes | -922,337,203,685,477.5808 to 922,337,203,685,477.5807 |
| smallmoney | 4 bytes | -214,748.3648 to 214,748.3647 |

- Accurate to 1/10000 (4 decimal places).
- Currency symbols accepted in input but not stored.
- Subject to rounding through truncation; use decimal for calculations.

## 3. Approximate Numeric Types

### float

**Syntax:** `float[(n)]` where n = 1-53. Default = 53.

| n value | Precision | Storage |
|---------|-----------|---------|
| 1-24 | 7 digits | 4 bytes |
| 25-53 | 15 digits | 8 bytes |

**Range:** -1.79E+308 to -2.23E-308, 0, 2.23E-308 to 1.79E+308.

**Synonym:** `double precision` = `float(53)`.

### real

- Storage: 4 bytes. Range: -3.40E+38 to -1.18E-38, 0, 1.18E-38 to 3.40E+38.
- Synonym: `float(24)` = `real`.

## 4. Date and Time Types

### date

| Property | Value |
|----------|-------|
| Storage | 3 bytes |
| Range | 0001-01-01 to 9999-12-31 |
| Accuracy | 1 day |
| Default | 1900-01-01 |

### time

**Syntax:** `time[(n)]` where n = 0-7. Default = 7.

| Scale | Storage |
|-------|---------|
| 0-2 | 3 bytes |
| 3-4 | 4 bytes |
| 5-7 | 5 bytes |

Range: 00:00:00.0000000 to 23:59:59.9999999. Default: 00:00:00.

### datetime

| Property | Value |
|----------|-------|
| Storage | 8 bytes |
| Date range | 1753-01-01 to 9999-12-31 |
| Time range | 00:00:00 to 23:59:59.997 |
| Accuracy | Rounded to .000, .003, or .007 seconds |
| Default | 1900-01-01 00:00:00 |

**Critical rounding:** Rounds to increments of 0, 3, 7 ms: .000, .003, .007, .010, .013, .017, .020, .023, .027, .030... Value .999 rounds UP to next second (cascades). .998/.997/.996/.995 → .997.

NOT ISO 8601 compliant. Use datetime2 for new work.

### smalldatetime

| Property | Value |
|----------|-------|
| Storage | 4 bytes |
| Date range | 1900-01-01 to 2079-06-06 |
| Accuracy | 1 minute |
| Default | 1900-01-01 00:00:00 |

Rounding: 29.998s or less → round down to minute. 29.999s or more → round up. Can cascade (12:59:30 → 13:00:00).

### datetime2

**Syntax:** `datetime2[(n)]` where n = 0-7. Default = 7.

| Scale | Storage |
|-------|---------|
| 0-2 | 6 bytes |
| 3-4 | 7 bytes |
| 5-7 | 8 bytes |

Date range: 0001-01-01 to 9999-12-31. Accuracy: 100ns. Default: 1900-01-01 00:00:00.

### datetimeoffset

**Syntax:** `datetimeoffset[(n)]` where n = 0-7. Default = 7.

| Scale | Storage |
|-------|---------|
| 0-2 | 8 bytes |
| 3-4 | 9 bytes |
| 5-7 | 10 bytes |

TZ offset range: -14:00 to +14:00. Stored/compared/sorted in UTC. Offset is preserved.

Both the displayed local value and its UTC-normalized instant must be within
`0001-01-01` through `9999-12-31`; for example, midnight on `0001-01-01
+14:00` is invalid because its UTC instant is in year 0. Conversion rounds to
the declared scale and carries into the next/previous civil day when needed.
Equality and ordering compare UTC instants, so `10:00 +02:00` equals `08:00
+00:00`, while formatting, `DATEPART(tzoffset, ...)`, and `DATENAME(tzoffset,
...)` retain the original offset.

### Date/Time Default Conversion Rules

- DATE only supplied → TIME defaults to 00:00:00, TIMEZONE to +00:00.
- TIME only supplied → DATE defaults to 1900-01-01, TIMEZONE to +00:00.
- DATE + TIMEZONE without TIME → **not allowed**.

## 5. Character String Types

### char / varchar

| Type | Syntax | Storage | Max |
|------|--------|---------|-----|
| char(n) | n = 1-8000 | n bytes (fixed) | 8000 bytes |
| varchar(n) | n = 1-8000 | actual + 2 bytes | 8000 bytes |
| varchar(max) | — | variable | 2^31-1 bytes (2 GB) |

- Default n = 1 in declarations, 30 in CAST/CONVERT.
- char is space-padded. n is bytes, not characters.

### nchar / nvarchar

| Type | Syntax | Storage | Max |
|------|--------|---------|-----|
| nchar(n) | n = 1-4000 | 2*n bytes (fixed) | 8000 bytes |
| nvarchar(n) | n = 1-4000 | 2*actual + 2 bytes | 8000 bytes |
| nvarchar(max) | — | variable | 2^31-1 chars (2 GB) |

- UTF-16 encoding. Supplementary characters use surrogate pairs.
- Prefix Unicode constants with `N` (e.g., `N'text'`).
- `sysname` = nvarchar(128), not nullable.

### text / ntext (DEPRECATED)

Use varchar(max) / nvarchar(max) instead.

## 6. Binary String Types

### binary / varbinary

| Type | Syntax | Storage | Max |
|------|--------|---------|-----|
| binary(n) | n = 1-8000 | n bytes (fixed, 0x00-padded) | 8000 bytes |
| varbinary(n) | n = 1-8000 | actual + 2 bytes | 8000 bytes |
| varbinary(max) | — | variable | 2^31-1 bytes (2 GB) |

String types to binary: padded/truncated on the right. Other types to binary: padded/truncated on the left.

## 7. Other Types

### uniqueidentifier

- Storage: 16 bytes. Format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
- Generated via NEWID() or NEWSEQUENTIALID().
- Comparison operators supported. Ordering is NOT by bit pattern.
- No arithmetic operators.

### sql_variant

- Max 8,016 bytes. Stores values of most types.
- Cannot contain: varchar(max), nvarchar(max), varbinary(max), text, ntext, image, xml, timestamp, geography, geometry, hierarchyid, UDTs.
- Must CAST to base type before arithmetic.
- Implicit conversion TO sql_variant supported. FROM sql_variant requires explicit CAST.

### sql_variant Comparison Families (highest to lowest)

| Family | Types |
|--------|-------|
| Date/time | datetime2, datetimeoffset, datetime, smalldatetime, date, time |
| Approximate numeric | float, real |
| Exact numeric | decimal, money, smallmoney, bigint, int, smallint, tinyint, bit |
| Unicode | nvarchar, nchar, varchar, char |
| Binary | varbinary, binary |
| Uniqueidentifier | uniqueidentifier |

Different families: higher family is greater. Same family: lower type implicitly converted to higher.

### mssqlite opaque compatibility floor

- `sql_variant` is stored as the TDS SSVARIANT instance (base token,
  properties, and bare value), so base numeric/text/binary identity survives
  SQLite persistence. Casts out unpack the base value. Variant operators are
  rejected until SQL Server's comparison-family ordering is implemented.
- Untyped `xml` accepts and preserves a Unicode string and returns native TDS
  XML. XML schema collections, well-formedness validation, operators, and XML
  methods are not implemented and fail explicitly.
- `hierarchyid`, `geometry`, and `geography` accept only their native serialized
  bytes (`0x...`/`varbinary`) and return native TDS UDT metadata plus the same
  bytes. Text constructors, CLR methods, comparisons, and indexing are deferred.
  Keeping the binary serialization opaque avoids inventing an incompatible
  text representation.

## 8. Data Type Synonyms

| Synonym | Maps to |
|---------|---------|
| binary varying | varbinary |
| char varying / character varying(n) | varchar / varchar(n) |
| character / character(n) | char / char(n) |
| dec | decimal |
| double precision | float(53) |
| integer | int |
| national character(n) / national char(n) | nchar(n) |
| national character varying(n) / national char varying(n) | nvarchar(n) |
| national text | ntext |
| rowversion | timestamp |

Synonyms are invisible after object creation — metadata reports the base type.

## 9. Quick Reference Table

| Type | Category | Storage | Default p/s |
|------|----------|---------|-------------|
| tinyint | Exact numeric | 1 byte | 3, 0 |
| smallint | Exact numeric | 2 bytes | 5, 0 |
| int | Exact numeric | 4 bytes | 10, 0 |
| bigint | Exact numeric | 8 bytes | 19, 0 |
| bit | Exact numeric | 1 bit* | 1, 0 |
| decimal(p,s) | Exact numeric | 5-17 bytes | p=18, s=0 |
| money | Exact numeric | 8 bytes | 19, 4 |
| smallmoney | Exact numeric | 4 bytes | 10, 4 |
| float(n) | Approximate | 4 or 8 bytes | n=53 |
| real | Approximate | 4 bytes | 7 digits |
| date | Date/time | 3 bytes | 10, 0 |
| time(n) | Date/time | 3-5 bytes | n=7 |
| datetime | Date/time | 8 bytes | — |
| smalldatetime | Date/time | 4 bytes | — |
| datetime2(n) | Date/time | 6-8 bytes | n=7 |
| datetimeoffset(n) | Date/time | 8-10 bytes | n=7 |
| char(n) | Character | n bytes | n=1 |
| varchar(n\|max) | Character | actual+2 | n=1 (30 in CAST) |
| nchar(n) | Unicode | 2*n bytes | n=1 |
| nvarchar(n\|max) | Unicode | 2*n+2 | n=1 (30 in CAST) |
| binary(n) | Binary | n bytes | n=1 |
| varbinary(n\|max) | Binary | actual+2 | n=1 (30 in CAST) |
| uniqueidentifier | Other | 16 bytes | — |
| sql_variant | Other | up to 8,016 | — |
