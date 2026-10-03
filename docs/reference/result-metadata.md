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
| 0x10 | identity | identity base column, *without* 0x08 (flags 16/17) |
| 0x20 | computed | any non-column expression (32/33) |
| none | | UNION outputs and VALUES-derived columns: 0; aggregates: 0x01 only |

OUTPUT columns referencing inserted/deleted keep base-column flags; in MERGE
both images are nullable (flags 9) and `$action` is nvarchar(10) with flags 0.

A constant CASE that folds to a column keeps that column's base flags
(`CASE WHEN 1=1 THEN v ELSE 7 END` gives 9).

A hidden ORDER BY key (ORDER token ordinal 0: the key is not an output alias,
position or select-list expression) clears 0x20 on every computed column of
that SELECT: literals report 0, nullable expressions 1; base columns keep
8/9 (`query/order-hidden-key`). An ORDER BY key that calls a user function is
never matched to an identical select item, so it is always hidden
(`udf/scalar-basics`).

User functions (`udf/*`): a scalar UDF call is a computed column with the
declared RETURNS type, always nullable (33), also with
constant arguments. Inline table-valued function columns follow views: base
columns keep 8/9, computed ones (and parameter references) 33.
Multi-statement table-valued function columns report the declared return
table like a table variable (NOT NULL 8, nullable 9). OUTER APPLY makes the
right side nullable.

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
- Arithmetic is nullable if an operand is; exact-numeric arithmetic is
  always nullable. Folding a constant does not change that: `1+1` and `2*3`
  are IntN 33, `1.5*2` NumericN 33, while `N'a'+N'b'`, `'a'+'b'+'c'`,
  `1e0+1` and `0x01+0x02` are NOT NULL (32), and `'a'+NULL` is 33
  (collation/expression-metadata). Constant arithmetic that fails at
  compile time (`1/0`, `2147483647+1`) stays a run-time expression and is
  nullable (IntN 33) even though its operands are literals.
- An integer literal (also negated or parenthesized) in arithmetic with a
  decimal operand is typed `numeric(digits, 0)`: `1.5*2` is numeric(4,1),
  `1.5*20` numeric(5,1), `1.5+-2` numeric(3,1), `2/2147483649`
  numeric(12,11); a non-literal int stays int (`1.5*CAST(2 AS int)` and
  `2.5*@@TRANCOUNT` are numeric(13,1)). The same rule unifies CASE / IIF /
  COALESCE branches (`CASE WHEN 1=0 THEN 1 ELSE 2.5 END` is numeric(2,1),
  traps/metadata-not-from-values, functions/logic#022).
- `LEN`, `TRIM`-family and most string functions: nullable.
- `ISNULL(a, b)`: type of `a`, nullable only if both are, where an argument
  that is a constant folding to a non-NULL value counts as NOT NULL even if
  it alone reports nullable: `ISNULL(CAST(NULL AS int), CAST(1 AS int))`
  and `ISNULL(.., 1+1)` are int 32, `ISNULL(.., LEFT('abc',2))` 32, but
  `ISNULL(.., CHAR(NULL))` and `ISNULL(.., 1/0)` 33 (msduck
  character-result-flags #003, space-capacity #012, probes in
  collation/expression-metadata).
- `NULLIF(a, b)`: type of `a`, where an integer literal `a` is typed by its
  value: 0..255 tinyint, -32768..32767 smallint, else int (`NULLIF(1,1)` is
  IntN(1), `NULLIF(300,1)` smallint, `NULLIF(-1,-1)` smallint,
  `NULLIF(32768,0)` int, `NULLIF(1+1,0)` int, `NULLIF(1,@x)` tinyint). A
  constant NULLIF folds: to NULL (nullable, `a`'s type) when equal, else to
  `a` unchanged (`NULLIF(1,2)` is tinyint 32, `NULLIF(1,NULL)` tinyint 32,
  `NULLIF('a','b')` varchar(1) 32). Evidence: functions/logic#023,
  collation/expression-metadata.
- `JSON_QUERY`: nvarchar(max) only when its input is max, else
  nvarchar(4000) (traps/json-lax-strict, collation/expression-metadata).

## String concatenation (`+`)

- Unicode if either side is; lengths add up, capped at 8000 bytes
  (varchar(8000) / nvarchar(4000)); max if either side is max.
- Two fixed-length operands give a fixed result: char+char is char,
  char+nchar / nchar+char / nchar+nchar nchar (capped char(8000) /
  nchar(4000)); one varying operand makes it varying (msduck
  character-concat-declarations, collation/expression-metadata).
- An untyped NULL next to a string counts as varchar(1): `N'a'+NULL` is
  nvarchar(2), `CAST('a' AS CHAR(2))+NULL` varchar(3), `NULL+CAST('a' AS
  NCHAR(2))` nvarchar(3); `NULL+NULL` stays int (msduck character-concat
  #022).
- `@@TRANCOUNT`, `@@ROWCOUNT`, `@@ERROR`: `int` non-null (flags 32). `XACT_STATE()`: `smallint` nullable (IntN(2) 33).
- Aggregates: `COUNT(*)` IntN(4) flags 1, `COUNT_BIG` IntN(8), `SUM(int)` int, `AVG(int)` int.

## Constant folding (CASE / IIF / COALESCE)

From msduck `conditional-literal-folding` and `case-constant-properties`:

1. Leading WHEN branches whose condition is constant FALSE are dropped. A
   constant TRUE condition selects its branch (COALESCE's `x IS NOT NULL`
   tests on constants count).
2. When the selected branch's type equals the CASE type up to length and
   fixed/varying (same character set: char/varchar, nchar/nvarchar, or
   binary/varbinary), the result is that branch unchanged: its own length
   (`CASE WHEN 1=1 THEN N'a' ELSE N'longer' END` gives nvarchar(1)),
   nullability and column origin. `IIF(1=1, CAST('a' AS char(2)), 'abc')`
   is char(2), `IIF(1=1, CHAR(65), 'abc')` char(1) (msduck
   character-result-flags #003, collation/expression-metadata).
3. Otherwise the branch is converted to the CASE type (all branches unified).
   The result is nullable if any branch is (an untyped `NULL` literal does
   not count: `CASE WHEN 1=1 THEN 'a' ELSE N'longer' END` gives
   nvarchar(6), flags 32), or if the conversion can cut the value: a
   4001-character literal against `N'x'` is nvarchar(4000) flags 33, a
   4000-character one flags 32 (msduck conditional-literal-folding #012,
   probes).
4. LOB results (`max`) are never folded: unified type, nullable when any branch is.
5. Branch types unify without untyped `NULL` branches (`IIF(1=1, NULL,
   N'x')` is nvarchar(1), `COALESCE(NULL, N'longer')` nvarchar(6)); a
   varchar longer than 4000 meeting nvarchar unifies to nvarchar(4000).
6. Conditions fold through deterministic string built-ins over constants
   (LEFT, RIGHT, SPACE, CHAR, NCHAR, LEN, `+`, CAST, COLLATE…): `CASE WHEN
   LEFT(N'🦆',0) COLLATE Latin1_General_100_BIN2 = N'' THEN 1 WHEN NOT (…)
   THEN 0 ELSE NULL END` is int NOT NULL (msduck bin2-constant-edges,
   bin2-comparisons, bin2-ansi-comparisons). A condition that folds to
   UNKNOWN (`CHAR(256)`, `SPACE(-1)`, NULL operands) falls through to the
   ELSE NULL (IntN 33).

## Open questions (need captures)

- Folded function results take the length of their value (`LEFT('abcdef',3)`
  gives varchar(3), `SPACE(3)` varchar(3)). The REPLICATE edge cases (`''`, `0`) are not understood yet.
- Expressions over VALUES-derived columns: a non-constant CASE over them showed flags 0 (msduck conditional-literal-folding #006).

## Collation precedence (bind/collation.mbt)

Coercibility: `COLLATE` gives explicit, column references implicit, literals
and variables default. Derived tables, CTEs and views pass their column's
coercibility through: `SELECT N'a' COLLATE BIN2 AS x` read back as `x` is
still explicit (468 against another explicit collation), `SELECT N'a' AS x`
read back stays default (no conflict with an implicit column) (msduck
collation-precedence #000–#002, #020, #021). String-to-string CAST keeps the
input's label. `ISNULL(a, b)` takes `a`'s collation, `b`'s only when `a` is
an untyped NULL (msduck collation-functions #001–#003, #042–#045); NULLIF
takes its first argument's.

Two different implicit collations combine to **no collation** in operators
that do not compare (`+`, CONCAT, CASE / IIF / COALESCE / CHOOSE, UNION
ALL). What then happens (msduck bin2-comparisons, collation-precedence,
collation-sensitive; corpus collation/deferred-conflicts):

| Situation | Error |
| --- | --- |
| two different explicit collations meet anywhere, or two different implicit ones meet directly in a collation-sensitive operation (comparison, LIKE, IN, REPLACE, STUFF, NULLIF, UNION, INTERSECT, EXCEPT) | 468 state 9 "Cannot resolve the collation conflict between "<later operand>" and "<earlier operand>" in the <equal to \| replace \| UNION \| …> operation." |
| a no-collation operand reaches a collation-sensitive operation (comparisons, LIKE, IN, any string function but CONCAT: LEN, UPPER, LEFT, REPLACE, …; MIN/MAX) and no explicit collation repairs it | 4191 state 9 "Cannot resolve collation conflict for <equal to \| like \| len \| replace \| max …> operation." |
| a no-collation value becomes a result column (SELECT list, also through CAST, derived tables, scalar subqueries, SELECT INTO) | 451 state 1 "Cannot resolve collation conflict between "<later>" and "<earlier>" in <add \| concat \| CASE \| CHOOSE \| UNION ALL> operator occurring in SELECT statement column <n>." |
| a no-collation value is assigned (`INSERT … SELECT a+b`, `SELECT @v = a+b`) or given an explicit collation (`(a+b) COLLATE X`) | none |

Notes: COALESCE and IIF report "CASE operator". SQL Server reports one 451
per offending column (bitsql: the first only), and with two such columns
the collation order inside the message flips (unexplained; bitsql always
names the later operand first). ORDER BY / GROUP BY keys give "ORDER BY
statement column n" / "GROUP BY statement column n" (not implemented).

## Code page 1252 conversion

Unicode → char/varchar (CAST, assignment, non-N literals in batch text)
converts each UTF-16 code unit on its own (captured over all 65,536 units
by harness/gen/cp1252-best-fit.mjs, identical under SQL_Latin1_General_CP1_CI_AS,
Latin1_General_100_CI_AS and Latin1_General_BIN2):

- 256 units map exactly (CP1252, including U+0081/8D/8F/90/9D as the
  undefined bytes);
- 452 more map by Windows "best fit" (`Ā` → `A`, `Đ` → `Ð`, `∞` → `8`,
  U+0301 → `´` 0xB4), table in src/core/types/cp1252_best_fit.mbt;
- every other unit becomes `?`, surrogate halves included, so a
  supplementary character becomes `??` (msduck left-right-casts #001:
  `CAST(LEFT(N'🦆xy',2) AS VARCHAR(3))` is `??`, unicode-bindings #003/#006).

Binary collations compare varchar data by these bytes: `'€'` (0x80) <
NBSP (0xA0) as varchar under BIN2 although U+20AC > U+00A0 (msduck
bin2-ansi-comparisons). Under SQL_ collations varchar uses string sort:
`'ß'` sorts after `'ss'` and before `'st'` but is not equal to `'ss'`
(`CHARINDEX('ss', 'straße')` is 0; nvarchar `ß` = `ss`).
