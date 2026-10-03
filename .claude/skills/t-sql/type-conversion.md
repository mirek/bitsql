# T-SQL Type Conversion

## 1. CAST / CONVERT

```sql
CAST(expression AS data_type [(length)])
CONVERT(data_type [(length)], expression [, style])
```

- CAST is ANSI SQL standard. CONVERT is SQL Server-specific with `style` parameter.
- Return type: the specified `data_type`.
- NULL input returns NULL.
- Deterministic except when converting to/from datetime with certain styles.

### TRY_CAST / TRY_CONVERT

```sql
TRY_CAST(expression AS data_type [(length)])
TRY_CONVERT(data_type [(length)], expression [, style])
```

Returns NULL on conversion failure instead of error. Still raises error for explicitly disallowed conversions (e.g., int → xml).

## 2. CONVERT Style Codes

### Date/Time Styles

| Style | Format | Example |
|-------|--------|---------|
| 0/100 | mon dd yyyy hh:miAM | Jan 01 2024 12:00PM |
| 1/101 | mm/dd/yyyy | 01/01/2024 |
| 2/102 | yyyy.mm.dd | 2024.01.01 |
| 3/103 | dd/mm/yyyy | 01/01/2024 |
| 4/104 | dd.mm.yyyy | 01.01.2024 |
| 5/105 | dd-mm-yyyy | 01-01-2024 |
| 8/108 | hh:mi:ss | 12:30:45 |
| 10/110 | mm-dd-yyyy | 01-01-2024 |
| 11/111 | yyyy/mm/dd | 2024/01/01 |
| 12/112 | yyyymmdd | 20240101 |
| 14/114 | hh:mi:ss:mmm | 12:30:45:123 |
| 20/120 | yyyy-mm-dd hh:mi:ss | 2024-01-01 12:30:45 |
| 21/121 | yyyy-mm-dd hh:mi:ss.mmm | 2024-01-01 12:30:45.123 |
| 23 | yyyy-mm-dd | 2024-01-01 |
| 25 | yyyy-mm-dd hh:mi:ss.mmm | 2024-01-01 12:30:45.123 |
| 126 | yyyy-mm-ddThh:mi:ss.mmm | 2024-01-01T12:30:45.123 |
| 127 | yyyy-mm-ddThh:mi:ss.mmmZ | 2024-01-01T12:30:45.123Z |

### Float Styles

| Style | Behavior |
|-------|----------|
| 0 | Max 6 digits, scientific when needed (default) |
| 1 | Always 8 digits, scientific notation |
| 2 | Always 16 digits, scientific notation |
| 3 | Always 17 digits, lossless round-trip |

### Money Styles

| Style | Behavior |
|-------|----------|
| 0 | No commas, 2 decimal places (default) |
| 1 | Commas every 3 digits, 2 decimal places |
| 2 | No commas, 4 decimal places |

## 3. Implicit Conversion Rules

### Always Implicit (key paths)

- tinyint → smallint → int → bigint
- Integer types → decimal/numeric, float, real, money
- Smaller date/time → larger (date → datetime2, smalldatetime → datetime)
- char/varchar → nchar/nvarchar
- All types → sql_variant (but NOT from sql_variant)
- Numeric to character (assignment only)

### Require Explicit CAST/CONVERT

- sql_variant → any other type
- Character types → binary (except varchar → varbinary)
- nchar → binary
- Between incompatible families (e.g., date → time: error)

### Key Conversion Behaviors

- `int + varchar`: varchar is converted to int (higher precedence wins). If varchar can't parse as int → error.
- Empty string → int: returns 0.
- Empty string → date: returns 1900-01-01.
- When converting to shorter character type: **truncated** (no error).
- When converting numeric to smaller type: may overflow (error).

## 4. Cross-Type Conversion Details

### String to Numeric
- Must consist of digits, optional decimal point, optional +/-.
- For money: optional $ and comma separators allowed.
- For float: optional exponential notation (e/E with optional +/-).

### String to Date/Time
- Depends on SET DATEFORMAT and SET LANGUAGE.
- GETDATE() implicitly converts to date style 0.
- SYSDATETIME() implicitly converts to date style 21.

### Date/Time Cross-Conversions

| From | To | Behavior |
|------|----|----------|
| date | time | FAILS (error 206) |
| date | datetime | date copied, time = 00:00:00.000 |
| date | datetime2(n) | date copied, time = 00:00:00.0000000 |
| date | datetimeoffset(n) | date copied, time = 00:00:00.0000000, offset = +00:00 |
| time | date | FAILS (error 206) |
| time | datetime | date = 1900-01-01, time truncated to 3 digits |
| time | datetime2(n) | date = 1900-01-01, time copied |
| datetime | date | date extracted |
| datetime | time | time extracted |
| datetime | datetime2(n) | date/time copied, precision extended to n digits |
| datetime2 | datetime | truncated to 3 fractional digits |
| datetimeoffset | datetime2 | date/time copied, timezone truncated |
| datetimeoffset | datetime | date/time copied, timezone truncated, fractional truncated |
| smalldatetime | datetime2(n) | hours/minutes copied, seconds/fractional = 0 |

## 5. Truncation vs Rounding

| Scenario | Behavior |
|----------|----------|
| finite numeric/decimal/float → integer | **truncated toward zero before range checking** |
| empty or whitespace character → integer | **zero** |
| datetime fractional > 3 digits → datetime | **truncated** |
| Character → shorter character | **truncated** |
| decimal → lower precision/scale | **rounded** (by default) |
| time(n) → lower precision | **rounded up** |
| smalldatetime rounding | 29.998s down, 29.999s up to nearest minute |
| datetime rounding | To .000/.003/.007 ms increments |

## 6. Operator Type Resolution

1. Same type operands → result is that type with its precision/scale.
2. Different types → convert lower-precedence to higher-precedence.
3. Decimal result → apply arithmetic precision/scale formulas (see data-types.md §2).
4. Precision and scale capped at 38.

## 7. Default Value Behavior

- Empty string → int = 0.
- Empty string → date = 1900-01-01.
- Date/time defaults: date component defaults to 1900-01-01 when converting from time-only.
- Time component defaults to 00:00:00 when converting from date-only.
- Timezone defaults to +00:00 for datetimeoffset conversions.

## 8. PARSE / TRY_PARSE

```sql
PARSE(string_value AS data_type [USING culture])
TRY_PARSE(string_value AS data_type [USING culture])
```

- CLR-dependent. Only converts string → date/time and number types.
- Culture parameter: .NET culture (e.g., 'en-US', 'de-DE').
- TRY_PARSE returns NULL on failure. PARSE raises error.
- Significantly slower than CAST/CONVERT due to CLR overhead.
- Nondeterministic.

## 9. Concatenation Length Rules

- char + char / varchar + varchar: sum of lengths, up to 8,000 bytes.
- nchar + nchar / nvarchar + nvarchar: sum of lengths, up to 4,000 byte-pairs.
- If either operand is varchar(max)/nvarchar(max): result is max type.
- UNION/EXCEPT/INTERSECT of same type but different lengths: result uses the longer.
