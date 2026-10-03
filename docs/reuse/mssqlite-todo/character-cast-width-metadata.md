# Character CAST width metadata

## Evidence

The differential case `character width values` runs:

```sql
SELECT CAST('abcdefghijklmnopqrstuvwxyz1234567890' AS VARCHAR) AS cast_value,
  ISNULL(CAST(NULL AS VARCHAR(3)), 'abcdef') AS isnull_value
```

Both servers correctly truncate `cast_value` to 30 characters, which is the
T-SQL default width for CAST/CONVERT with an omitted character length. SQL
Server advertises `varchar(30)` (`dataLength = 30`); mssqlite advertises
`varchar(1)` (`dataLength = 1`). The latter is the declaration default and must
not be reused for conversion expressions.

## Work

Preserve the parser's declaration-versus-conversion context in the inferred
result descriptor. Audit `char`, `varchar`, `nchar`, and `nvarchar`, including
CAST, CONVERT, TRY_CAST, and TRY_CONVERT. Unicode lengths must remain TDS byte
lengths.

Likely boundaries are the T-SQL type parser, transpile conversion hints, and
engine projection metadata.

## Acceptance

- The exact `/execution/results/0/columns/0/length` expectation in the live
  case becomes stale and is removed.
- Focused tests prove omitted declaration width 1 versus omitted conversion
  width 30 for all four character families, including empty results.
- `pnpm test` and `pnpm test:differential` pass.
