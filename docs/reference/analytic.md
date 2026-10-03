# Analytic and JSON constructor rules

Rules derived from captures against SQL Server 17.0.5005.3, corpus
`harness/corpus/analytic/` and `harness/corpus/json2/`. The binder and
executor implement them (`bind/pivot.mbt`, `bind/analytic.mbt`,
`exec/analytic.mbt`, `bind|exec/fn_parse.mbt`, `bind|exec/fn_date_bucket.mbt`,
`json/modify.mbt`, `bind|exec/fn_json2.mbt`).

## PIVOT (analytic/pivot, pivot-errors, pivot-text)

- `src PIVOT (agg(col) FOR pcol IN ([v1], v2, ...)) [AS] alias` applies to the
  table source written before it, which may be a join tree (`a JOIN b ON ..
  PIVOT (..) p`). Joins may follow. The alias is required; a column list
  after it is 102 near its first name.
- The aggregate takes exactly one column name (qualified allowed). `COUNT(*)`,
  `SUM(a + 1)`, `SUM(DISTINCT a)`, two aggregates, `STRING_AGG(a, ',')` are
  syntax errors (102/156) at the offending token. Allowed: COUNT,
  COUNT_BIG, SUM, AVG, MIN, MAX, STDEV(P), VAR(P), APPROX_COUNT_DISTINCT.
  CHECKSUM_AGG is 406, LEN/GROUPING 195 (class 15), `dbo.f` 208 state 214.
- Grouping is by every source column except the value and pivot columns, in
  source order. Grouping columns keep their own metadata (flags 8/9 for base
  columns, 0 for VALUES columns). Value columns are named by the IN
  identifiers as written, typed as the aggregate (SUM(decimal(10,2)) is
  decimal(38,2), AVG(smallint) int, COUNT int, COUNT_BIG bigint), flags 1.
- IN values convert from nvarchar to the pivot column's type at compile time
  (`[true]` matches bit 1, `[20240102]` a date); a failure is 8114 "Error
  converting data type nvarchar to int." followed by 473 'The incorrect value
  "abc" is supplied in the PIVOT operator.'. Matching uses the pivot column's
  collation (`[EAST]` matches 'east').
- Names: an IN value equal to a grouping column name is 265 + 8156; repeated
  IN values (case-insensitive, trailing spaces ignored: `[east]`,
  `[EAST ]`) and duplicate grouping column names (a join's two `id`s) are
  8156.
- No grouping columns: one row, or no row for empty input (GROUP BY ()).
- No warning 8153, except with APPROX_COUNT_DISTINCT (which reports it).
- Without ORDER BY, rows came sorted by the grouping columns with one key.
  With several keys the order was plan-dependent (two-key captures sorted
  by the second key first, three-key ones by the first); bitsql sorts by
  the grouping columns in order. Write ORDER BY.
- Non-comparable grouping/pivot columns (text, ntext, image, xml) are 488;
  bitsql has none of these types yet (pivot-text stays failing).

## UNPIVOT (analytic/unpivot)

- `src UNPIVOT (v FOR k IN (c1, c2, ...)) alias`: per source row, one row per
  IN column (in IN-list order) whose value is not NULL.
- Output columns: the remaining source columns (own metadata), then `v`,
  then `k`. `v` has the IN columns' type (all must be identical including
  length and collation, else 8167 naming the first differing column), flags
  0/1 by the IN columns' nullability (NOT NULL base columns give flags 0).
  `k` is nvarchar(128), nullable (flags 1), database collation, holding the
  source column's own spelling (`IN (Q1)` yields 'q1').
- Errors: repeated IN column 277 (checked before names resolve), unknown 207,
  `v` or `k` equal to a remaining column 265 + 8156, `v` = `k` 8156, the
  source alias is not visible outside (`w.id` is 4104).

## PERCENTILE_CONT / PERCENTILE_DISC (analytic/percentile)

- Window functions only: `f(p) WITHIN GROUP (ORDER BY key) OVER ([PARTITION
  BY ...])`. No OVER is 10753 state 3; no WITHIN GROUP 10754; ORDER BY in OVER
  10758; a frame 10752 state 1; more than one key 10751; two arguments 174.
- `p` must be constant (literal, constant expression, string, variable);
  a column is 8726. NULL or outside [0, 1] is 8727 at run time, after the
  column metadata.
- CONT: float, flags 1; the key must be numeric (402 "The data types numeric
  and datetime are incompatible in the percentile_cont operator."). With n
  non-NULL values sorted by the key, rn = 1 + p(n-1), f = floor(rn), c =
  ceil(rn): v[f] if f = c, else (c - rn)·v[f] + (rn - f)·v[c] in double
  (reproduces 1.7999999999999998 for {1.5, 2.5} at 0.3 and
  4.400000000000001 for {0.5, 7, 9}).
- DISC: the key's type, nullable only if the key is; the first value whose
  position i/n reaches p (p = 0 gives the first value).
- Key constants are 5309, integer literals 5308.

## Window frames (analytic/window-frames)

- RANGE takes only UNBOUNDED and CURRENT ROW bounds (4194); SQL Server has no
  RANGE offsets, so bitsql's 4194 is faithful.
- Offsets are unsigned integer literals up to 2147483647; variables,
  parentheses, signs, decimals and larger numbers are 102 near the token.
- `UNBOUNDED FOLLOWING` as start and `UNBOUNDED PRECEDING` as end are 102
  near the keyword. A frame with neither PARTITION BY nor ORDER BY is 102
  near ROWS/RANGE; with PARTITION BY only, 10756.
- 4193: `BETWEEN n FOLLOWING AND m PRECEDING` state 1, `n FOLLOWING AND
  CURRENT ROW` (also short form `ROWS n FOLLOWING`) state 4, `CURRENT ROW
  AND n PRECEDING` state 5. `2 FOLLOWING AND 1 FOLLOWING` is an empty frame.
- 10752: ROW_NUMBER, RANK, DENSE_RANK, NTILE, PERCENT_RANK, CUME_DIST state
  3; LAG, LEAD, PERCENTILE_* state 1.

## STRING_AGG (analytic/string-agg-checks)

- Separator: a string literal (also `'a' + 'b'`), NULL or a variable;
  `CAST(',' AS varchar(1))` or a column is 8733, a subquery 130, a
  non-string 8116; an nvarchar separator with a char/varchar value is 8116.
- `STRING_AGG(DISTINCT ..)` is 102 near ','. OVER is 4113 state 4. WITHIN
  GROUP: an integer literal key is 5308, a subquery 130, `CAST(1 AS int)`
  is allowed. ROLLUP/CUBE is 8710.
- Non-max results over 8000 bytes: 9829, state 0 for varchar, 1 for
  nvarchar, after the column metadata.

## APPROX_COUNT_DISTINCT, CHECKSUM_AGG (analytic/approx-checksum-agg)

- APPROX_COUNT_DISTINCT: bigint, flags 1, 0 over no rows, NULLs ignored
  (8153), collation-aware. Exact up to 30 distinct values in every capture
  (8 types × 3 sequences); the HyperLogLog estimate first differed at 31
  (100 values give 99). bitsql raises 50151 above 30 and under ROLLUP/CUBE,
  where SQL Server carries the sketch across groups (a, b, c gave 2, 4, 4).
  DISTINCT is 16200, OVER 4113 state 5, `*` 102.
- CHECKSUM_AGG: XOR of the values; int only (bigint, smallint, tinyint,
  decimal, float, strings, bit are 8117); NULL over no values; DISTINCT
  works; also a windowed aggregate.

## GENERATE_SERIES (analytic/generate-series)

- Table-valued only (`SELECT GENERATE_SERIES(..)` is 195 state 10; a column
  alias list is 195 state 15; `dbo.GENERATE_SERIES` 208). 2 or 3 arguments
  (313 state 3 / 8144 state 3).
- Column `value`: integer arguments must share one type; decimal ones may
  differ in precision/scale (result: widest integral part + scale), but
  decimal and numeric do not mix. Mismatch is 5373 (state 1 for start/stop,
  2 for step), an unsupported type 8116 (state = argument position); both
  are followed by one 206 "Operand type clash: X is incompatible with void
  type" per argument. Untyped NULLs take the others' type.
- Integer results are nullable when an argument is (variables, CASTs);
  literals give flags 0; decimal results were NOT NULL even over CASTs.
- Default step is 1 or -1 toward stop; a wrong-sign step or any NULL gives no
  rows; a zero step is 4199 (state 1 at compile time for a constant, state 2
  at run time for a variable). Values stop at the type's limits without
  overflow.

## TABLESAMPLE (analytic/tablesample, unsupported)

- `t [AS x] TABLESAMPLE [SYSTEM] (n [PERCENT|ROWS]) [REPEATABLE (seed)]`
  before table hints, local tables only (views 494, derived tables and table
  variables 156). Errors: 476 (percent outside 0..100, `"%f"` text), 479
  (ROWS or seed ≤ 0), 482 (NULL), 497 (variables; a compile error of the
  whole batch).
- 100 PERCENT returns every row and 0 PERCENT none. Anything else samples
  pages nondeterministically (even REPEATABLE depends on page layout); bitsql
  raises 50150.

## Literals

- `-2147483648` and `-(2147483648)` are int, not numeric(10,0)
  (VALUES rows, GENERATE_SERIES arguments).

## JSON_OBJECT / JSON_ARRAY (json2/json-object, json-array)

- nvarchar(max), flags 33. JSON_OBJECT defaults to NULL ON NULL, JSON_ARRAY
  to ABSENT ON NULL. Values from JSON_OBJECT, JSON_ARRAY, JSON_QUERY and FOR
  JSON subqueries (with the array wrapper) are embedded raw; a variable
  holding JSON text, JSON_VALUE and FOR JSON ... WITHOUT_ARRAY_WRAPPER are
  escaped strings. Duplicate keys are kept; non-string keys print as text.
- A NULL key is 13638 at run time. `JSON_OBJECT('a', 1)` is 102 state 10.
- Values format like FOR JSON (money 4 decimals, real 8 significant digits,
  float 16, binary base64); date/time values drop an all-zero fraction.

## JSON_MODIFY (json2/json-modify*)

- Edits the text in place: a replace swaps only the value's text (first of
  duplicate keys); a lax insert adds `,"k":v` right before the closing `}`
  after any whitespace there (`{"a":1 }` → `{"a":1 ,"b":2}`); append works
  before `]`, and a missing key in append mode gets `"k":[v]`.
- A lax NULL removes the member with its preceding comma, or its following
  comma when it is the first member, keeping other whitespace. NULL on an
  array element or under strict writes `null`.
- Lax paths through missing/mistyped steps return the text unchanged; strict
  ones are 13608 state 2. `$` alone is 13619, `[*]` 13660 state 4, path
  syntax 13607 (state 22 at the mode/`$`, 21 in `[...]`, 14 elsewhere).
- New values: strings, integers, decimal (scale kept), float/real (16
  digits), bit; others are 8116 (argument 3). A typed NULL path is 8116
  state 8 at run time; an untyped NULL path 8116 state 1.

## PARSE / TRY_PARSE (analytic/parse-*)

- .NET number styles: integers and decimal use NumberStyles.Number
  (thousands only after a digit, trailing sign, zero fractions for
  integers), float NumberStyles.Float, money NumberStyles.Currency. Decimal
  rounds half away from zero; overflow is NULL / 9819. All results flags 33;
  a decimal target reports NumericN.
- Cultures: en-US (any case, `en`, `en_US`) and `iv`; '' / 'Invariant' /
  NULL are 9818 at run time; others 50171 in bitsql. 9819 names culture ''
  without USING.
- Dates: a captured subset (ISO with -, / or ., M/d/yyyy, M/d/yy with the
  2049 cutoff, captured month-name forms, H:mm[:ss[.f]] with AM/PM).
  Clock- or time-zone-dependent text (time only, no year, zone designators)
  is 50172.

## DATE_BUCKET (analytic/date-bucket*)

- Origin 1900-01-01 (a Monday). Fixed-length parts use floor division from
  the origin; month/quarter/year step like DATEADD, backing off one width
  when DATEADD(month, k, origin) passes the date (origin 01-31, date 02-29
  gives 02-29, date 02-28 gives 01-31). datetimeoffset buckets in UTC and
  keeps the input offset; time wraps at midnight. Result precision is the
  larger of date and origin precision; width truncates from numeric/float.
- Errors: 9834 (width ≤ 0), 9835 (overflow), 9810 (run time for
  microsecond/nanosecond/dayofyear/weekday/iso_week/tzoffset, compile time
  for a time part on date or a date part on time), 155/1023/189 spell
  "Date_Bucket". Year/quarter widths overflowing int32 months are 50170.
