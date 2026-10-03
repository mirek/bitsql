# T-SQL Language Elements

## 1. Operator Precedence (highest to lowest)

| Level | Operators |
|-------|-----------|
| 1 | `~` (bitwise NOT) |
| 2 | `*`, `/`, `%` |
| 3 | `+` (add/concat), `-` (subtract), `&`, `^`, `\|`, `<<`, `>>` |
| 4 | `=`, `>`, `<`, `>=`, `<=`, `<>`, `!=`, `!>`, `!<` |
| 5 | `NOT` |
| 6 | `AND` |
| 7 | `ALL`, `ANY`, `BETWEEN`, `IN`, `LIKE`, `OR`, `SOME` |
| 8 | `=` (assignment) |

Same-level: left-to-right. Parentheses override.

## 2. Arithmetic Operators

| Op | Semantics |
|----|-----------|
| `+` | Addition. Also datetime +/- int (days). |
| `-` | Subtraction. |
| `*` | Multiplication. |
| `/` | Division. Integer division truncates. Division by zero → error. |
| `%` | Modulo — integer remainder. |

- Operands must be numeric. Result type follows data type precedence.
- Any arithmetic with NULL → NULL.

## 3. Comparison Operators

| Op | Meaning | Non-ISO |
|----|---------|---------|
| `=` | Equal | |
| `<>` | Not equal | `!=` |
| `>` | Greater than | |
| `<` | Less than | |
| `>=` | Greater than or equal | |
| `<=` | Less than or equal | |
| | Not less than | `!<` |
| | Not greater than | `!>` |

- Return: Boolean (TRUE, FALSE, UNKNOWN).
- Any comparison with NULL → UNKNOWN (with ANSI_NULLS ON, default).
- When ANSI_NULLS OFF: `NULL = NULL` → TRUE.
- Cannot use on text, ntext, image.

## 4. Logical Operators

| Op | Result |
|----|--------|
| `AND` | TRUE if both TRUE |
| `OR` | TRUE if either TRUE |
| `NOT` | Reverses boolean |

### Three-Valued Logic (UNKNOWN)

| AND | TRUE | FALSE | UNKNOWN |
|-----|------|-------|---------|
| TRUE | TRUE | FALSE | UNKNOWN |
| FALSE | FALSE | FALSE | FALSE |
| UNKNOWN | UNKNOWN | FALSE | UNKNOWN |

| OR | TRUE | FALSE | UNKNOWN |
|----|------|-------|---------|
| TRUE | TRUE | TRUE | TRUE |
| FALSE | TRUE | FALSE | UNKNOWN |
| UNKNOWN | TRUE | UNKNOWN | UNKNOWN |

`NOT UNKNOWN` = UNKNOWN.

## 5. Bitwise Operators

| Op | Semantics |
|----|-----------|
| `&` | Bitwise AND |
| `\|` | Bitwise OR |
| `^` | Bitwise XOR |
| `~` | Bitwise NOT (unary, ones' complement) |
| `<<` | Left shift (SQL Server 2022+) |
| `>>` | Right shift (SQL Server 2022+) |

- Operands: integer types or binary/varbinary (but not both binary).
- Result type: int for int input, smallint for smallint, tinyint for tinyint, bit for bit.
- `~` on tinyint vs int: different results because of byte width.

## 6. Unary Operators

| Op | Semantics |
|----|-----------|
| `+` (positive) | No-op. Does NOT convert negative to positive (use ABS). |
| `-` (negative) | Negates value. tinyint promotes to smallint. |
| `~` (NOT) | Ones' complement. Integer types only. |

## 7. String Operators

| Op | Semantics |
|----|-----------|
| `+` | Concatenation. |
| `+=` | Concatenate and assign. |

- Return type: highest precedence of operands.
- `CONCAT_NULL_YIELDS_NULL ON` (default): string + NULL = NULL.
- `CONCAT_NULL_YIELDS_NULL OFF`: NULL treated as empty string.
- Truncated at 8000 bytes unless operand is varchar(max)/nvarchar(max).
- `'' + 'abc'` = `'abc'` — empty string is not NULL.

## 8. Compound Assignment Operators

```
+=  -=  *=  /=  %=  &=  ^=  |=
```

`@x += 2` ≡ `@x = @x + 2`. Returns type of higher-precedence argument.

## 9. Expressions

```
expression ::=
    constant | scalar_function | [table.]column | @variable
    | ( expression ) | ( scalar_subquery )
    | unary_operator expression | expression binary_operator expression
    | ranking_windowed_function | aggregate_windowed_function
```

- Two expressions can combine if same type or lower precedence can implicitly convert.
- Maximum SELECT list expressions: 4,096.

## 10. CASE Expression

### Simple CASE
```sql
CASE input_expression
    WHEN when_expression THEN result_expression [...n]
    [ELSE else_result_expression]
END
```

### Searched CASE
```sql
CASE
    WHEN boolean_expression THEN result_expression [...n]
    [ELSE else_result_expression]
END
```

- Evaluates WHEN clauses sequentially, returns first match.
- No match and no ELSE → NULL.
- Return type: highest precedence among all result expressions.
- At least one result must not be NULL constant (error 8133).
- Max nesting: 10 levels.
- CASE is an expression, not a statement.

## 11. Predicate Expressions

### BETWEEN
```sql
expr [NOT] BETWEEN begin AND end
```
Inclusive: `expr >= begin AND expr <= end`. All three must be same type.

### IN
```sql
expr [NOT] IN (subquery | value_list)
```
NULL with NOT IN: may return UNKNOWN instead of TRUE (surprising behavior).

### LIKE
```sql
string_expr [NOT] LIKE pattern [ESCAPE escape_char]
```

| Wildcard | Meaning |
|----------|---------|
| `%` | Zero or more characters |
| `_` | Any single character |
| `[abc]` / `[a-f]` | Character in set/range |
| `[^abc]` / `[^a-f]` | Character NOT in set/range |

- ESCAPE: treats next wildcard character as literal.
- Pattern max: 8000 bytes.
- Non-Unicode: trailing blanks NOT significant. Unicode: trailing blanks ARE significant.

### EXISTS
```sql
EXISTS ( subquery )
```
TRUE if subquery returns any rows. Column values irrelevant.

### ALL / SOME / ANY
```sql
expr { = | <> | < | > | <= | >= } { ALL | SOME | ANY } ( subquery )
```
- ALL: TRUE if comparison holds for ALL rows or subquery returns 0 rows.
- SOME/ANY (synonyms): TRUE if holds for at least one row. FALSE if 0 rows.

### IS [NOT] DISTINCT FROM
```sql
expr IS [NOT] DISTINCT FROM expr
```
NULL-safe equality. `NULL IS NOT DISTINCT FROM NULL` → TRUE (two-valued, no UNKNOWN).

## 12. Variables

### DECLARE
```sql
DECLARE @var data_type [= value] [, ...n]
DECLARE @cursor CURSOR
DECLARE @tbl TABLE (column_defs...)
```
- Initialized to NULL unless value provided.
- Scoped to the **batch** (not BEGIN...END blocks).
- Cannot be text, ntext, or image.

### SET @variable
```sql
SET @var = expression
SET @var {+= | -= | *= | /= | %= | &= | ^= | |=} expression
```
- With subquery: `SET @var = (SELECT ...)` — must return single value.
- One variable per SET statement.

### SELECT @variable
```sql
SELECT @var = expression [, ...n]
```
- Multiple rows: variable gets the **last** value.
- No rows: variable **retains its current value** (not set to NULL).
- Scalar subquery returning no value: variable IS set to NULL.
- Cannot mix with regular SELECT output.

**Key difference:** SET sets to NULL on no rows; SELECT leaves unchanged.

## 13. Control Flow

### IF...ELSE
```sql
IF boolean_expression
    { statement | statement_block }
[ELSE
    { statement | statement_block }]
```
FALSE and UNKNOWN both take the ELSE branch. Without BEGIN...END, only one statement governed.

### WHILE
```sql
WHILE boolean_expression
    { statement | statement_block | BREAK | CONTINUE }
```
- BREAK: exits innermost loop.
- CONTINUE: restarts from condition check.
- Nestable. Inner BREAK exits to next outer loop.
- mssqlite's server execution yields and checks its AbortSignal before the
  condition/body on every interpreted iteration. Attention therefore exits a
  long loop without emitting accumulated batch output; synchronous direct
  engine execution retains its original non-yielding behavior.

### BEGIN...END
```sql
BEGIN
    { statement | statement_block }
END
```
- Groups statements. Does NOT create scope — variables visible outside.
- Must contain at least one statement.
- Does NOT provide atomicity.
- Cannot span batches (no GO inside).

### GOTO
```sql
label:
GOTO label
```
- Unconditional jump within same batch.
- Cannot enter TRY/CATCH from outside (can jump within or exit).

### RETURN
```sql
RETURN [integer_expression]
```
- Exits procedure/batch immediately. Returns int (0 = success convention).
- Cannot return NULL (returns 0 with warning).
- Capture: `EXEC @status = proc_name`.

### WAITFOR
```sql
WAITFOR { DELAY 'hh:mm:ss[.fff]' | TIME 'hh:mm:ss[.fff]' }
```
- DELAY: pause for duration (max 24 hours).
- TIME: pause until clock time.
- Blocks batch/transaction.

### PRINT
```sql
PRINT msg_str | @variable | string_expr
```
Sends message to client. Truncated at 8000/4000 chars.

### EXECUTE
```sql
EXEC [@return =] module_name [params...]
EXEC ({@string_var | [N]'tsql'} [+ ...])
```
Executes stored procedure or dynamic SQL string.

## 14. Cursors

### State Machine
```
DECLARED → OPENED → (FETCHING) → CLOSED → DEALLOCATED
```

### DECLARE CURSOR
```sql
DECLARE cursor_name CURSOR [LOCAL | GLOBAL]
    [FORWARD_ONLY | SCROLL]
    [STATIC | KEYSET | DYNAMIC | FAST_FORWARD]
    [READ_ONLY | SCROLL_LOCKS | OPTIMISTIC]
    FOR select_statement
    [FOR UPDATE [OF column_name [,...n]]]
```

| Type | Behavior |
|------|----------|
| STATIC | Temp copy in tempdb. Base table changes not reflected. |
| KEYSET | Keys fixed at OPEN. Non-key changes visible; deletes → @@FETCH_STATUS = -2. |
| DYNAMIC | All changes visible. No ABSOLUTE/RELATIVE fetch. |
| FAST_FORWARD | FORWARD_ONLY + READ_ONLY with optimizations. |
| FORWARD_ONLY | Default. Only FETCH NEXT. |

### OPEN / FETCH / CLOSE / DEALLOCATE

```sql
OPEN cursor_name
FETCH [NEXT|PRIOR|FIRST|LAST|ABSOLUTE n|RELATIVE n] FROM cursor INTO @vars
CLOSE cursor_name
DEALLOCATE cursor_name
```

@@FETCH_STATUS: 0 = success, -1 = failed/beyond, -2 = row missing, -9 = not fetching.

## 15. NULL and UNKNOWN

- NULL = unknown value. Different from empty or zero.
- No two NULLs are equal (ANSI_NULLS ON).
- Use `IS NULL` / `IS NOT NULL` to test.
- WHERE only returns TRUE rows (UNKNOWN excluded).
- Cannot be PRIMARY KEY.

## 16. Reserved Keywords (partial list)

ADD, ALL, ALTER, AND, ANY, AS, ASC, AUTHORIZATION, BEGIN, BETWEEN, BREAK, BY, CASCADE, CASE, CHECK, CLOSE, CLUSTERED, COALESCE, COLLATE, COLUMN, COMMIT, CONSTRAINT, CONTINUE, CONVERT, CREATE, CROSS, CURRENT, CURSOR, DATABASE, DEALLOCATE, DECLARE, DEFAULT, DELETE, DENY, DESC, DISTINCT, DROP, ELSE, END, ESCAPE, EXCEPT, EXEC, EXECUTE, EXISTS, EXIT, FETCH, FOR, FOREIGN, FROM, FULL, FUNCTION, GOTO, GRANT, GROUP, HAVING, IDENTITY, IF, IN, INDEX, INNER, INSERT, INTERSECT, INTO, IS, JOIN, KEY, LEFT, LIKE, MERGE, NATIONAL, NOCHECK, NONCLUSTERED, NOT, NULL, NULLIF, OF, OFF, ON, OPEN, OPTION, OR, ORDER, OUTER, OVER, PERCENT, PIVOT, PRIMARY, PRINT, PROC, PROCEDURE, PUBLIC, RAISERROR, READ, REFERENCES, RETURN, REVOKE, RIGHT, ROLLBACK, ROWCOUNT, RULE, SAVE, SCHEMA, SELECT, SET, SOME, TABLE, THEN, THROW, TO, TOP, TRAN, TRANSACTION, TRIGGER, TRUNCATE, UNION, UNIQUE, UNPIVOT, UPDATE, USE, USER, VALUES, VIEW, WAITFOR, WHEN, WHERE, WHILE, WITH.

Delimited identifiers: `[keyword]` or `"keyword"`.
