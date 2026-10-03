# T-SQL Queries

## 1. Logical Processing Order

The binding order determines name resolution and data flow. Physical execution may differ.

```
 1. FROM        (including JOINs, APPLY, PIVOT)
 2. ON          (join predicates, per join)
 3. JOIN        (outer rows added after ON)
 4. WHERE       (filter rows; no aggregates)
 5. GROUP BY    (partition into groups)
 6. WITH CUBE / ROLLUP
 7. HAVING      (filter groups; aggregates allowed)
 8. SELECT      (evaluate expressions, aliases created)
 9. DISTINCT    (remove duplicates)
10. ORDER BY    (sort; can reference SELECT aliases)
11. TOP         (limit rows from sorted result)
```

**Key implications:**
- SELECT aliases NOT visible to WHERE, GROUP BY, HAVING.
- SELECT aliases ARE visible to ORDER BY.
- ORDER BY can reference FROM columns not in SELECT (unless DISTINCT/UNION/EXCEPT/INTERSECT).
- Without ORDER BY, row order is undefined.

## 2. SELECT Statement — Complete Syntax

```sql
[ WITH cte [,...n] ]
<query_expression>
[ ORDER BY ... ]
[ OPTION ( query_hint [,...n] ) ]

<query_expression> ::=
    { <query_spec> | ( <query_expression> ) }
    [ { UNION [ALL] | EXCEPT | INTERSECT } <query_spec> | ( <query_expression> ) [...n] ]

<query_spec> ::=
SELECT [ ALL | DISTINCT ]
    [ TOP (expr) [PERCENT] [WITH TIES] ]
    <select_list>
    [ INTO new_table ]
    [ FROM { <table_source> } [,...n] ]
    [ WHERE <search_condition> ]
    [ GROUP BY <group_by_clause> ]
    [ HAVING <search_condition> ]
```

## 3. SELECT Clause

```sql
SELECT [ ALL | DISTINCT ]
    { * | table.* | expression [[AS] alias] | alias = expression } [,...n]
```

- ALL (default): include duplicates. DISTINCT: remove duplicates (NULLs considered equal).
- Max 4,096 expressions in select list.
- Column aliases: `AS alias` or `alias = expr`. Cannot use in WHERE/GROUP BY/HAVING.

## 4. FROM Clause — Tables, Joins, APPLY, PIVOT

### Join Types

| Join | Semantics |
|------|-----------|
| INNER JOIN | Only matching rows from both tables. Default for plain `JOIN`. |
| LEFT [OUTER] JOIN | All left rows; matched right or NULL. |
| RIGHT [OUTER] JOIN | All right rows; matched left or NULL. |
| FULL [OUTER] JOIN | All rows from both; NULLs for unmatched sides. |
| CROSS JOIN | Cartesian product. No ON clause. |

### ON vs WHERE for OUTER JOINs (critical)

- **ON** predicates: applied BEFORE outer join adds unmatched rows (filter match candidates).
- **WHERE** predicates: applied AFTER join (filters combined result).
- For INNER JOINs: semantically equivalent.
- For OUTER JOINs: moving predicate from ON to WHERE can convert to effective INNER JOIN (NULL-padded rows fail WHERE).

### APPLY Operator

```sql
left_table { CROSS | OUTER } APPLY right_table_expression
```

- CROSS APPLY: Right evaluated per left row. Left rows excluded if right empty.
- OUTER APPLY: Like CROSS but left rows retained with NULLs if right empty.
- Right can reference left columns (correlated).

### PIVOT / UNPIVOT

- PIVOT: rows → columns. Requires aggregate + value column + pivot column + IN list.
- UNPIVOT: columns → rows. Inverse of PIVOT.
- Both require table alias.

### Derived Tables

```sql
FROM (SELECT ...) AS T(col1, col2)
FROM (VALUES (1,2),(3,4)) AS T(a,b)
```

- Must be aliased. No row limit for VALUES as derived table.
- A column alias list is optional syntactically, but every VALUES expression is
  unnamed: omitting it raises 8155. Alias-list width errors are 8158/8159,
  duplicate names are 8156, and unequal row widths are 10709.
- Column types use the same precedence and widening rules as UNION ALL; a
  higher-precedence type may therefore make another row fail conversion.
- Up to 256 table sources per statement.
- `FROM A, B` ≡ `FROM A CROSS JOIN B`.

## 5. WHERE and Search Conditions

```sql
<search_condition> ::=
    { [NOT] <predicate> | ( <search_condition> ) }
    [ { AND | OR } [NOT] { <predicate> | ( <search_condition> ) } ] [...]

<predicate> ::=
    expr { = | <> | != | > | >= | !> | < | <= | !< } expr
    | string [NOT] LIKE pattern [ESCAPE char]
    | expr [NOT] BETWEEN expr AND expr
    | expr IS [NOT] NULL
    | expr IS [NOT] DISTINCT FROM expr
    | expr [NOT] IN (subquery | value_list)
    | expr { = | <> | < | > | <= | >= } { ALL | SOME | ANY } (subquery)
    | EXISTS (subquery)
```

- Three-valued logic: only TRUE rows pass (UNKNOWN filtered out).
- No aggregate functions in WHERE (use HAVING).

### NULL Handling in Predicates

| Context | Behavior |
|---------|----------|
| `x = NULL` | UNKNOWN |
| `NULL = NULL` | UNKNOWN |
| `IS NULL` / `IS NOT NULL` | Proper test (TRUE/FALSE) |
| `IS [NOT] DISTINCT FROM` | NULL-safe equality (TRUE/FALSE only) |
| `x IN (1, NULL)` | x=1 → TRUE; x=2 → UNKNOWN (not FALSE) |
| `NOT UNKNOWN` | UNKNOWN |

## 6. GROUP BY

```sql
GROUP BY {
    column_expr
    | ROLLUP ( expr [,...n] )
    | CUBE ( expr [,...n] )
    | GROUPING SETS ( grouping_set [,...n] )
    | ()
} [,...n]
```

- Every non-aggregate SELECT column must appear in GROUP BY.
- NULLs grouped together as one group.
- Cannot contain subqueries.
- Column aliases from SELECT cannot be used.

### ROLLUP / CUBE / GROUPING SETS

- `ROLLUP(A, B, C)` → (A,B,C), (A,B,NULL), (A,NULL,NULL), (NULL,NULL,NULL) — N+1 levels.
- `CUBE(A, B)` → (A,B), (A,NULL), (NULL,B), (NULL,NULL) — all 2^N combinations.
- `GROUPING SETS((A,B), (A), ())` → exactly those groupings.
- `GROUP BY ()` → grand total (single row).

## 7. HAVING

```sql
HAVING <search_condition>
```

- Filters groups after GROUP BY. Can use aggregates (unlike WHERE).
- Without GROUP BY, implicit single group over all rows.

## 8. ORDER BY with OFFSET/FETCH

```sql
ORDER BY expr [COLLATE name] [ASC|DESC] [,...n]
[OFFSET {int|expr} {ROW|ROWS}]
[FETCH {FIRST|NEXT} {int|expr} {ROW|ROWS} ONLY]
```

- ASC default. NULLs sort as lowest (first in ASC, last in DESC).
- Can use: column names, aliases, expressions, ordinal positions (>= 1).
- With DISTINCT/UNION/EXCEPT/INTERSECT: can only reference SELECT list columns.
- Not valid in subqueries/views unless TOP or OFFSET/FETCH specified.
- OFFSET >= 0. FETCH >= 1. Cannot combine with TOP.
- ROW/ROWS synonyms. FIRST/NEXT synonyms.
- OFFSET without FETCH: returns all after skipping.

## 9. TOP

```sql
TOP (expression) [PERCENT] [WITH TIES]
```

- Without ORDER BY: arbitrary N rows.
- PERCENT: rounded UP to next integer.
- WITH TIES: includes tied rows beyond N. Requires ORDER BY. Can return > N rows.
- Cannot combine with OFFSET/FETCH.

## 10. OVER Clause (Window Functions)

```sql
function OVER (
    [PARTITION BY expr [,...n]]
    [ORDER BY expr [ASC|DESC] [,...n]]
    [{ROWS|RANGE} <frame>]
)

<frame> ::=
    <bound> | BETWEEN <bound> AND <bound>

<bound> ::=
    UNBOUNDED PRECEDING | N PRECEDING | CURRENT ROW | N FOLLOWING | UNBOUNDED FOLLOWING
```

### PARTITION BY
- Divides result into partitions. Function computed per partition.
- Omitted → entire result is one partition.

### ORDER BY (within OVER)
- Defines logical order within partition. Independent of statement ORDER BY.
- With ORDER BY but no ROWS/RANGE: default frame = `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`.
- Without ORDER BY: entire partition is the frame.

### ROWS vs RANGE

- **ROWS**: Physical rows. `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW` = exactly 3 rows.
- **RANGE**: Logical values. `RANGE BETWEEN CURRENT ROW AND CURRENT ROW` includes all rows with same ORDER BY value.
- RANGE does NOT support N PRECEDING/FOLLOWING (only UNBOUNDED and CURRENT ROW).

### Default Frame Rules

| Condition | Default Frame |
|-----------|---------------|
| No ORDER BY | Entire partition |
| ORDER BY, no ROWS/RANGE | `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` |
| Single bound specified | `{ROWS\|RANGE} BETWEEN <bound> AND CURRENT ROW` |

### Function Categories

| Category | Functions | PARTITION BY | ORDER BY | ROWS/RANGE |
|----------|-----------|-------------|----------|------------|
| Ranking | ROW_NUMBER, RANK, DENSE_RANK, NTILE | Optional | Required | N/A |
| Aggregate | SUM, AVG, COUNT, MIN, MAX, etc. | Optional | Optional | Optional |
| Analytic | LAG, LEAD, FIRST_VALUE, LAST_VALUE | Optional | Required | Optional |

- Cannot use OVER with DISTINCT aggregations.

## 11. Common Table Expressions (CTEs)

```sql
WITH cte_name [(columns)] AS (query)
[, cte_name2 AS (...)]
```

### Non-Recursive Rules
- Followed by single SELECT/INSERT/UPDATE/MERGE/DELETE.
- Can reference itself and previously defined CTEs. No forward references.
- No nested WITH. No ORDER BY (unless TOP/OFFSET/FETCH), INTO, OPTION, FOR BROWSE.
- Not materialized — each reference re-executes.

### Recursive CTE

```sql
WITH RecCTE (cols) AS (
    SELECT ... FROM ...          -- anchor member(s)
    UNION ALL
    SELECT ... FROM ... JOIN RecCTE ON ...  -- recursive member(s)
)
SELECT * FROM RecCTE OPTION (MAXRECURSION N);
```

**Structure:**
- At least one anchor + one recursive member.
- Anchors first, combined with UNION ALL/UNION/INTERSECT/EXCEPT.
- Between anchor and recursive: only UNION ALL.

**Restrictions in recursive member:** No DISTINCT, GROUP BY, HAVING, aggregation, TOP, LEFT/RIGHT/FULL JOIN, subqueries, PIVOT.

**Control:** `OPTION (MAXRECURSION N)` — default 100, 0 = unlimited.

**Execution model:**
1. Execute anchor → Result_0
2. Execute recursive with CTE = Result_i → Result_(i+1)
3. If empty, stop. If i >= MAXRECURSION, error.
4. Final = UNION ALL of all Result_0..n.

All columns returned by recursive CTE are nullable.

## 12. Set Operations

### UNION
```sql
query UNION [ALL] query [...]
```
- UNION ALL: all rows including duplicates.
- UNION: deduplicates (NULLs considered equal).
- Column count and types must match (implicit conversion by precedence).
- Column names from first (leftmost) query.

### EXCEPT / INTERSECT
```sql
query { EXCEPT | INTERSECT } query
```
- EXCEPT: distinct left rows NOT in right (left anti-semi-join).
- INTERSECT: distinct rows in BOTH (left semi-join).
- Always return distinct rows. NULLs considered equal.

### Precedence
1. Parentheses (highest)
2. INTERSECT
3. EXCEPT and UNION (equal, left-to-right)

ORDER BY at end of chain. Must reference first SELECT columns.

## 13. Subqueries

### Types
1. **Scalar**: Single value. Anywhere an expression is valid.
2. **Row** (multi-column): With IN, EXISTS, comparisons.
3. **Table**: In FROM (derived table), EXISTS, IN.

### Correlation
- Non-correlated: evaluated once.
- Correlated: references outer query. Evaluated per outer row.
- Name resolution: inner FROM first, then outer (walking outward).

### Restrictions
- No ORDER BY (unless TOP/OFFSET/FETCH). No INTO.
- No text/ntext/image in select list with comparison operators.

## 14. OUTPUT Clause

```sql
OUTPUT { DELETED.* | INSERTED.* | from_table.col | $action } [,...n]
    [INTO @table_var | table [(columns)]]
```

- With INSERT, UPDATE, DELETE, MERGE.
- INSERTED.*: new values. DELETED.*: old values.
- $action (MERGE only): 'INSERT', 'UPDATE', 'DELETE'.
- No aggregate functions.

## 15. SELECT INTO

```sql
SELECT ... INTO new_table FROM ...
```

- Creates new table with inferred schema.
- IDENTITY transfers unless: join, UNION, multiple listings, expression, or remote source.
- Indexes, constraints, triggers NOT transferred.

## 16. Table Value Constructor

```sql
VALUES (expr [,...n]) [,...n]
```

- INSERT...VALUES: limited to 1,000 rows.
- FROM (VALUES...) AS T(cols): no row limit.
- Type per column: highest precedence across all rows.

## 17. Hints

### Query Hints (OPTION)
- `MAXRECURSION N`: CTE recursion limit (0-32767; default 100).
- `{ HASH | ORDER } GROUP`: force grouping algorithm.
- `{ CONCAT | HASH | MERGE } UNION`: force UNION implementation.
- `{ LOOP | MERGE | HASH } JOIN`: force join algorithm.
- `FORCE ORDER`: preserve join order.
- `RECOMPILE`: recompile plan.

### Join Hints
```sql
table_a INNER { LOOP | HASH | MERGE | REMOTE } JOIN table_b ON ...
```

### Table Hints
```sql
FROM table WITH (NOLOCK, INDEX(idx))
```

## 18. AT TIME ZONE

```sql
inputdate AT TIME ZONE timezone
```

- Converts to datetimeoffset in target timezone.
- Without offset: assumes input is in target timezone.
- With offset: performs conversion.
- DST-aware.

## 19. NULL Handling Summary

| Context | NULL Behavior |
|---------|---------------|
| Comparison (=, <>, etc.) | UNKNOWN |
| IS NULL / IS NOT NULL | TRUE/FALSE |
| IS [NOT] DISTINCT FROM | TRUE/FALSE (no UNKNOWN) |
| WHERE / HAVING | Only TRUE passes |
| GROUP BY | NULLs grouped together |
| DISTINCT | NULLs considered equal |
| UNION (without ALL) | NULLs equal for dedup |
| EXCEPT / INTERSECT | NULLs equal |
| ORDER BY ASC | NULLs first (lowest) |
| ORDER BY DESC | NULLs last (lowest) |
| OUTER JOIN unmatched | NULL for all unmatched columns |
| Aggregates | Ignore NULLs (except COUNT(*)) |
