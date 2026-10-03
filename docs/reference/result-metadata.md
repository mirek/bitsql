# Result metadata (COLMETADATA) rules

SQL Server's column metadata (type, length, precision/scale, flags) depends on
how an expression is written, not on row values. These rules come from captures
(harness corpus: msduck imports and traps). The binder implements them
(`src/core/bind`, `src/core/session/wire.mbt`). Add a rule here, with its
evidence, whenever a capture forces one.

## Flags word

| Bit | Meaning | When |
| --- | --- | --- |
| 0x01 | nullable | expression nullability (below) |
| 0x02 | case-sensitive | collation is CS, BIN or BIN2 (msduck collation-wire: 34/35) |
| 0x08 | updateable "unknown" | base table columns (`SELECT col FROM t`: 8/9) |
| 0x10 | identity | identity base column |
| 0x20 | computed | any non-column expression (32/33) |
| none | | UNION outputs and VALUES-derived columns: 0; aggregates: 0x01 only |

A constant CASE that folds to a column keeps that column's base flags
(`CASE WHEN 1=1 THEN v ELSE 7 END` gives 9).

## Types of literals

| Literal | Type | Example |
| --- | --- | --- |
| integer fitting int | `int`, non-null (flags 32) | `1` |
| larger integer | `numeric(digits, 0)` | `2147483648` gives numeric(10,0) |
| decimal | `numeric(p, s)`, s = fraction digits, p = integral digits without leading zeros + s | `1.50` gives numeric(3,2) |
| float (`1e0`) | `float` | |
| `'ab'` / `N'ab'` | `varchar(2)` / `nvarchar(2)`; empty literals still have length 1 | |
| `NULL` | `int`, nullable (IntN 33) | |

## Nullability

- Literals are non-null; `NULL`, variables and parameters are nullable.
- CAST/CONVERT results are **always nullable**, even of a literal (`CAST(1 AS int)` gives IntN 33).
- Arithmetic is nullable if an operand is. Constant arithmetic that fails at
  compile time (`1/0`, `2147483647+1`) stays a run-time expression and is
  nullable (IntN 33) even though its operands are literals.
- `LEN`, `TRIM`-family and most string functions: nullable.
- `ISNULL(a, b)`: type of `a`, nullable only if both are.
- `@@TRANCOUNT`, `@@ROWCOUNT`, `@@ERROR`: `int` non-null (flags 32). `XACT_STATE()`: `smallint` nullable (IntN(2) 33).
- Aggregates: `COUNT(*)` IntN(4) flags 1, `COUNT_BIG` IntN(8), `SUM(int)` int, `AVG(int)` int.

## Constant folding (CASE / IIF / COALESCE)

From msduck `conditional-literal-folding` and `case-constant-properties`:

1. Leading WHEN branches whose condition is constant FALSE are dropped. A
   constant TRUE condition selects its branch (COALESCE's `x IS NOT NULL`
   tests on constants count).
2. When the selected branch's type equals the CASE type up to length, the
   result is that branch unchanged: its own length (`CASE WHEN 1=1 THEN N'a'
   ELSE N'longer' END` gives nvarchar(1)), nullability and column origin.
3. Otherwise the branch is converted to the CASE type (all branches unified).
   The result is nullable if any branch is; an untyped `NULL` literal does not
   count (`CASE WHEN 1=1 THEN 'a' ELSE N'longer' END` gives nvarchar(6), flags 32).
4. LOB results (`max`) are never folded: unified type, nullable when any branch is.

## Open questions (need captures)

- Whether successful constant arithmetic (`1+1`) folds to a non-null literal (assumed yes).
- Folded function results take the length of their value (`LEFT('abcdef',3)`
  gives varchar(3), `SPACE(3)` varchar(3)). The REPLICATE edge cases (`''`, `0`) are not understood yet.
- Expressions over VALUES-derived columns: a non-constant CASE over them showed flags 0 (msduck conditional-literal-folding #006).
