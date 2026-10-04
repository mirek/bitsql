# Named windows, NEXT VALUE FOR … OVER, syntax error recovery, 8120 names

Rules captured on SQL Server 17.0.5005.3 (2026-10-04). Cases:
`harness/corpus/tail5/b1-named-window.sql`, `b1-next-value-over.sql`,
`b1-syntax-recovery.sql`, `b1-ungrouped-name.sql`; msduck
`distribution-reference#006`, `sequence-reference#005..#019`,
`gaps-merge#008`, `json-aggregates#033`, corpus `tail/tablevar-hints`.

## Named windows (`WINDOW` clause)

Code: `src/core/parse/window.mbt` (resolved while parsing into plain OVER
clauses; a look-ahead finds the SELECT's WINDOW clause before its select
list).

- `SELECT … FROM … WHERE … GROUP BY … HAVING … WINDOW w AS (spec)[, …]
  ORDER BY …`. `OVER w` and `OVER (w [PARTITION BY] [ORDER BY] [frame])`;
  a definition may name another one, also defined later (`w2 AS (w1 ORDER
  BY n)`, `v AS (w)`). `OVER (w)` alone is 102 near ')'. `WINDOW` is not
  reserved: `FROM t window` is an alias, `FROM t WINDOW w AS (` the clause;
  `WINDOW w (…)` is 102 near 'WINDOW'.
- Names are case-insensitive, local to their SELECT: a subquery does not
  see the outer windows (5362 state 3); the SELECT's own ORDER BY does
  (`ORDER BY SUM(n) OVER w`). Under UNION the ORDER BY key is 104.
- Elements may be added but never repeated: OVER repeating an element of
  its window (PARTITION BY, ORDER BY, frame) is 4123 state 2; a definition
  doing it 5367 state 2. Adding PARTITION BY to an ORDER BY-only window is
  allowed.
- Errors (class 15, the whole batch, nothing runs): 5362 "Window 'x' is
  undefined." state 3 (no WINDOW clause in that SELECT), 4 (the clause lacks
  the name), 7 (inside a definition, also `w AS (w)`); 16211 state 1
  repeated name; 5365 state 1 cycle; 5364 state 1 frame without ORDER BY
  (definition or merged OVER); 5366 "The function 'lag' must have an OVER
  clause or a WINDOW with ORDER BY." state 3 for ROW_NUMBER/RANK/
  DENSE_RANK/NTILE/PERCENT_RANK/CUME_DIST, state 2 for LAG/LEAD/
  FIRST_VALUE/LAST_VALUE, function name lower-case (without a named window
  the same omission stays 4112).

## NEXT VALUE FOR … OVER (ORDER BY …)

Code: parse/expr.mbt (shape errors), bind/analytic.mbt
`bind_next_value_window`, bind/ast_walk.mbt (11720/11723/11727/11739),
exec/window.mbt (`NextValue`, streaming).

- Values are drawn in the OVER order, independent of the query's ORDER BY
  (`OVER (ORDER BY n DESC) … ORDER BY n` gives 6, 5, 4). References of one
  sequence with the same OVER share the value per row (`ASC` = default);
  different OVER clauses, or OVER mixed with a plain reference, are 11727
  (class 16). Result flags 0 like plain NEXT VALUE FOR.
- Single-row contexts accept OVER (`INSERT … VALUES`, `DECLARE @v = …`);
  `SELECT @v = … FROM t` keeps the last value in OVER order; SELECT INTO and
  INSERT … SELECT work; GROUP BY keys may be the OVER keys.
- Errors (class 15 whole-batch unless noted): 11716 PARTITION BY, 11718
  empty OVER, 11737 ROWS/RANGE, 11717 in UPDATE / MERGE / DEFAULT (a
  DEFAULT with a subquery is 1046 first), 11720 in WHERE or ORDER BY,
  11721 DISTINCT/UNION, 11739 TOP/OFFSET (also plain NEXT VALUE FOR), 11723
  plain NEXT VALUE FOR in a query with ORDER BY, 11719 in a subquery, 5308
  `ORDER BY 1`.
- An exhausted sequence (11728) streams the rows numbered before it, in OVER
  order, then the error.
- `OVER (ORDER BY SUM(n) OVER ())` kills the SQL Server session (596,
  severity 21): not captured, not emulated.

## Syntax error recovery

Code: `src/core/parse/recovery.mbt` `batch_errors` (the session prints every
error, then DONE 253; `npm run parse-diff` now compares the full list).

- After an error at a `WITH` token, 319 follows at the same token (the
  `WITH` restarts as an unterminated CTE statement): `UPDATE @t WITH
  (ROWLOCK)`, `INSERT INTO @t WITH (TABLOCK)`, `MERGE @t WITH (HOLDLOCK)`
  (table variables take no hints: 156 then 319), `MERGE items AS target WITH
  (HOLDLOCK)`. `DELETE FROM @t WITH (…)` is 319 alone (the DELETE is
  complete).
- Then statements restart at later tokens; a further error is reported only
  after three tokens were accepted since the last one (yacc's rule):
  `SELECT 1 x y; SELECT 2 a b` is 102 'y' + 102 'b'; `SELECT 1 x y; UPDATE`
  only 102 'y'; `… USING (SELECT 1 AS a) s` restarts at the parenthesized
  query and adds 102 near 's'. Only 102/156/319 recover.

## 8120 / 8121 / 8127 column names

A base table, view or temp table is named as written in FROM, schema
included and delimiters removed, even when it has an alias:
`FROM dbo.gt AS a` → `'dbo.gt.g'`, `FROM DBO.GT` → `'DBO.GT.g'`,
`FROM gt a` → `'gt.g'`, `sys.objects.name`, `#tg.g`; derived tables use
their alias (`'d.g'`). A name ambiguous among the FROM sources is 209 even
when only one of them is grouped (`SELECT g … FROM gt a JOIN gt b … GROUP BY
b.g`).
