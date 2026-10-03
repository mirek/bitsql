# T-SQL DML Statements

## 1. INSERT

```sql
[WITH cte [,...n]]
INSERT [TOP (expression) [PERCENT]]
    [INTO] {table | @table_var}
    [(column_list)]
    [OUTPUT output_clause]
{
    VALUES ({DEFAULT | NULL | expression} [,...n]) [,...n]
  | derived_table
  | execute_statement
  | DEFAULT VALUES
}
```

### Semantic Rules
- VALUES: table value constructor for multi-row insert.
- DEFAULT VALUES: all columns get default values.
- Column list omitted: values for all columns in order (except IDENTITY, computed, timestamp).
- Missing columns receive: DEFAULT, NULL (if nullable), or error.
- IDENTITY: auto-generated unless SET IDENTITY_INSERT ON.
- Computed columns: always auto-generated, cannot be specified.
- timestamp/rowversion: auto-generated.
- INSERT...SELECT: bulk insert from query.
- INSERT...EXEC: insert from stored procedure results.
- OUTPUT inserted.*: returns inserted rows (useful for IDENTITY values).
- TOP (n): limits rows inserted from source.

### Error Conditions
- Constraint violation (PK, UNIQUE, FK, CHECK): entire statement fails.
- NOT NULL column with no value and no DEFAULT.
- Data truncation or type conversion failure.

## 2. UPDATE

```sql
[WITH cte [,...n]]
UPDATE [TOP (expression) [PERCENT]]
    {table | @table_var}
    SET
    { column = {expression | DEFAULT | NULL}
    | column {+= | -= | *= | /= | %= | &= | ^= | |=} expression
    | @variable = expression
    | @variable = column = expression
    | column.WRITE(expression, @offset, @length)
    } [,...n]
    [OUTPUT output_clause]
    [FROM table_source [,...n]]
    [WHERE {search_condition | CURRENT OF cursor}]
```

### Semantic Rules
- SET: simple assignment, compound operators, .WRITE() for partial LOB updates.
- DEFAULT: replaces with column's default value.
- FROM clause (T-SQL extension): multi-table updates via joins. **Nondeterministic** if multiple source rows match one target row.
- WHERE CURRENT OF: cursor-based update.
- TOP (n): arbitrary rows without ORDER BY.
- OUTPUT: deleted.* (old) and inserted.* (new).
- `@var = col = expr`: assigns to both variable and column simultaneously.
- IDENTITY columns cannot be updated.
- Computed columns cannot be updated.
- timestamp/rowversion: auto-updated.

### Error Conditions
- No matching rows: no error, @@ROWCOUNT = 0.
- Constraint violation: statement fails.
- Attempting to update IDENTITY column.

## 3. DELETE

```sql
[WITH cte [,...n]]
DELETE [TOP (expression) [PERCENT]]
    [FROM] {table | @table_var}
    [OUTPUT output_clause]
    [FROM table_source [,...n]]
    [WHERE {search_condition | CURRENT OF cursor}]
```

### Semantic Rules
- Without WHERE: deletes ALL rows.
- Two FROM clauses: first = target, second = join filtering.
- TOP (n): arbitrary rows without ORDER BY.
- OUTPUT deleted.*: returns deleted rows.
- Fires DELETE triggers.
- Locking: IX on table, X on rows.
- Logs individual row deletions.

### Error Conditions
- FK violation: error unless CASCADE DELETE defined.
- Trigger raises error.
- No matching rows: no error, @@ROWCOUNT = 0.

## 4. MERGE

```sql
[WITH cte [,...n]]
MERGE [TOP (expression) [PERCENT]]
    [INTO] target_table [AS alias]
    USING table_source [AS alias]
    ON search_condition
    [WHEN MATCHED [AND condition] THEN {UPDATE SET ... | DELETE}]
    [WHEN MATCHED [AND condition] THEN {UPDATE SET ... | DELETE}]
    [WHEN NOT MATCHED [BY TARGET] [AND condition] THEN INSERT [(columns)] VALUES (...)]
    [WHEN NOT MATCHED BY SOURCE [AND condition] THEN {UPDATE SET ... | DELETE}]
    [OUTPUT output_clause]
;  -- semicolon REQUIRED
```

### Semantic Rules
- WHEN MATCHED: source matches target. UPDATE or DELETE.
- WHEN NOT MATCHED [BY TARGET]: source row has no target match. INSERT only.
- WHEN NOT MATCHED BY SOURCE: target row has no source match. UPDATE or DELETE.
- Max 2 WHEN MATCHED clauses: first must have AND condition.
- Max 1 WHEN NOT MATCHED BY TARGET.
- Max 2 WHEN NOT MATCHED BY SOURCE: first must have AND condition.
- Two-clause MATCHED / BY SOURCE families must use one UPDATE and one DELETE;
  repeating an action is invalid regardless of conditions.
- OUTPUT: $action returns 'INSERT', 'UPDATE', 'DELETE'.
- @@ROWCOUNT: total of all operations.

### Error Conditions
- Multiple source rows match same target row (nondeterministic → error).
- Constraint violations.
- Missing semicolon terminator: error 10713, severity 15.
- Repeated action in one match family: error 10714, severity 15.
- A second MATCHED / BY SOURCE arm after an unconditional first arm: error
  5324, severity 16.
- Cannot use same table as target and source (use subquery/CTE as source).

## 5. TRUNCATE TABLE

```sql
TRUNCATE TABLE [database.[schema].|schema.]table_name
    [WITH (PARTITIONS ({partition_number | range} [,...n]))]
```

### Semantic Rules
- Removes ALL rows by deallocating pages (not row-by-row).
- Much faster than DELETE.
- Resets IDENTITY counter to seed.
- Table structure, constraints, indexes remain.
- **CAN be rolled back** within a transaction.
- Does NOT fire triggers.
- Requires ALTER permission.

### Restrictions
- Cannot truncate: tables referenced by FK (even if FK table empty), indexed views, replication, temporal tables, EDGE constraints.
- Self-referencing FK is allowed.

### TRUNCATE vs DELETE

| Feature | TRUNCATE | DELETE |
|---------|----------|--------|
| Speed | Fast (page deallocation) | Slow (row-by-row log) |
| WHERE clause | No | Yes |
| Triggers | Not fired | Fired |
| IDENTITY reset | Yes (to seed) | No |
| FK restrictions | Cannot if referenced | Fails per-row if FK violated |
| Rollback | Yes | Yes |
| Permission | ALTER | DELETE |

## 6. BULK INSERT

```sql
BULK INSERT [database.[schema].|schema.]table_name
    FROM 'data_file'
    [WITH (options)]
```

### Key Options

| Option | Default | Behavior |
|--------|---------|----------|
| FIELDTERMINATOR | `\t` (tab) | Field separator |
| ROWTERMINATOR | `\n` | Row separator |
| FORMAT | — | `'CSV'` for RFC 4180 parsing |
| FIRSTROW | 1 | First row to import |
| LASTROW | — | Last row to import |
| MAXERRORS | 10 | Max errors before abort |
| BATCHSIZE | entire file | Rows per transaction batch |
| CHECK_CONSTRAINTS | OFF | Enable constraint checking |
| FIRE_TRIGGERS | OFF | Enable INSERT triggers |
| KEEPIDENTITY | OFF | Preserve identity values from file |
| KEEPNULLS | OFF | Empty fields → NULL instead of DEFAULT |
| TABLOCK | OFF | Bulk update lock for performance |
| ORDER | — | Hint: file data is sorted |
| CODEPAGE | — | 'ACP' (ANSI), 'OEM', 'RAW' (no conversion) |
| DATAFILETYPE | 'char' | 'char', 'native', 'widechar', 'widenative' |
| ERRORFILE | — | File path for rejected rows |

### Rules
- Target table must exist.
- By default: constraints NOT checked, triggers NOT fired.
- Requires INSERT + ADMINISTER BULK OPERATIONS permissions.
- Data file must be server-accessible (not client).
- Cannot bulk insert into views.

## 7. OUTPUT Clause (cross-cutting)

Available on INSERT, UPDATE, DELETE, MERGE.

```sql
OUTPUT {DELETED.* | INSERTED.* | from_table.col | $action} [,...n]
    [INTO @table_var | table [(columns)]]
```

| Prefix | Meaning |
|--------|---------|
| INSERTED.* | New values (INSERT, UPDATE) |
| DELETED.* | Old values (DELETE, UPDATE) |
| $action | MERGE only: 'INSERT', 'UPDATE', 'DELETE' |

No aggregate functions in OUTPUT.

## 8. Common Table Expressions (cross-cutting)

Available with INSERT, UPDATE, DELETE, MERGE, SELECT.

```sql
WITH cte_name [(columns)] AS (select_statement)
[, cte_name2 AS (...)]
```

- Temporary named result set, scoped to single statement.
- See queries.md for full CTE rules including recursion.

## 9. TOP Clause (cross-cutting)

Available with INSERT, UPDATE, DELETE, SELECT.

```sql
TOP (expression) [PERCENT] [WITH TIES]
```

- Without ORDER BY: arbitrary row selection.
- WITH TIES: SELECT only (includes tied rows beyond N).
- PERCENT: percentage of rows, rounded UP.
