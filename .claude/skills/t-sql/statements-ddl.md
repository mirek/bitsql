# T-SQL DDL Statements

## 1. CREATE TABLE

```sql
CREATE TABLE [database.[schema].|schema.]table_name
(
  { column_definition | computed_column_definition | table_constraint } [,...n]
)
[ON {partition_scheme(col) | filegroup | "default"}]
```

### Column Definition
```sql
column_name data_type
  [COLLATE collation_name]
  [NULL | NOT NULL]
  [DEFAULT constant_expression]
  [IDENTITY [(seed, increment)] [NOT FOR REPLICATION]]
  [ROWGUIDCOL]
  [column_constraint [,...n]]
```

### Column Constraints
```sql
[CONSTRAINT name]
{
    PRIMARY KEY [CLUSTERED | NONCLUSTERED] [WITH (index_options)]
  | UNIQUE [CLUSTERED | NONCLUSTERED] [WITH (index_options)]
  | FOREIGN KEY REFERENCES ref_table [(ref_column)]
      [ON DELETE {NO ACTION | CASCADE | SET NULL | SET DEFAULT}]
      [ON UPDATE {NO ACTION | CASCADE | SET NULL | SET DEFAULT}]
  | CHECK [NOT FOR REPLICATION] (logical_expression)
}
```

### Table Constraints (multi-column)
```sql
[CONSTRAINT name]
{
    PRIMARY KEY (col [ASC|DESC] [,...n])
  | UNIQUE (col [ASC|DESC] [,...n])
  | FOREIGN KEY (col [,...n]) REFERENCES ref_table (ref_col [,...n])
      [ON DELETE/UPDATE actions]
  | CHECK (logical_expression)
}
```

### Computed Column
```sql
column_name AS expression [PERSISTED [NOT NULL]]
```

### Semantic Rules
- One PRIMARY KEY per table → creates clustered index by default.
- One IDENTITY column per table: tinyint, smallint, int, bigint, decimal(p,0), numeric(p,0). Default (1,1).
- UNIQUE treats NULL as a comparable key component: a single-column key allows
  one NULL, while a composite key rejects only a repeated complete tuple with
  the same NULL positions. Creates a nonclustered index by default.
- CHECK cannot reference other tables or contain subqueries.
- MAX 999 nonclustered indexes per table.
- Composite key: max 32 columns.

### Foreign Key Actions
| Action | Behavior |
|--------|----------|
| NO ACTION (default) | Error if referenced row deleted/updated |
| CASCADE | Propagate delete/update to referencing rows |
| SET NULL | Set FK columns to NULL (must be nullable) |
| SET DEFAULT | Set FK columns to DEFAULT (default must exist in referenced table) |

## 2. ALTER TABLE

```sql
ALTER TABLE table_name
{
    ALTER COLUMN column_name { new_type [NULL|NOT NULL] }
  | ADD { column_definition | computed_column | table_constraint } [,...n]
  | DROP { [CONSTRAINT] [IF EXISTS] name | COLUMN [IF EXISTS] name } [,...n]
  | { CHECK | NOCHECK } CONSTRAINT { ALL | name [,...n] }
  | { ENABLE | DISABLE } TRIGGER { ALL | name [,...n] }
  | WITH { CHECK | NOCHECK } ADD { table_constraint }
}
```

### Rules
- ALTER COLUMN: data type change requires implicit conversion compatibility.
- Cannot alter: timestamp columns, computed columns, columns in indexes (unless compatible change).
- Cannot drop columns used in indexes, constraints, or statistics.
- WITH CHECK: validates existing data. WITH NOCHECK: skips (constraint marked untrusted).
- SET in stored procedure/trigger restores on return.

## 3. DROP TABLE

```sql
DROP TABLE [IF EXISTS] [database.[schema].|schema.]table_name [,...n]
```

- Removes table, data, indexes, triggers, constraints, permissions.
- Views/procedures referencing table become invalid (not auto-dropped).
- Cannot drop if referenced by FOREIGN KEY (drop FK or referencing table first).

## 4. CREATE INDEX

```sql
CREATE [UNIQUE] [CLUSTERED | NONCLUSTERED] INDEX index_name
    ON table_name (column [ASC|DESC] [,...n])
    [INCLUDE (column [,...n])]
    [WHERE filter_predicate]
    [WITH (option [,...n])]
```

### Key Rules
- CLUSTERED: physically reorders data. One per table. No clustered = heap.
- NONCLUSTERED (default): separate structure. Up to 999 per table.
- UNIQUE: NULL participates in the complete key tuple; repeated tuples with
  matching NULL positions are duplicates.
- INCLUDE: non-key columns at leaf level for covering queries.
- Filtered: WHERE with comparisons, IS [NOT] NULL, AND, OR, IN, BETWEEN. No subqueries or functions.
- Composite: max 32 columns. Key size: 900 bytes (clustered), 1700 bytes (nonclustered).

### Key Options
| Option | Behavior |
|--------|----------|
| DROP_EXISTING | Replace existing index (more efficient than DROP+CREATE) |
| IGNORE_DUP_KEY | Warning instead of error on duplicate (multi-row inserts) |
| FILLFACTOR | 1-100 leaf page fill percentage |
| ONLINE | ON/OFF concurrent DML during index build |
| DATA_COMPRESSION | NONE, ROW, PAGE |

## 5. CREATE VIEW

```sql
CREATE [OR ALTER] VIEW [schema.]view_name [(columns)]
    [WITH {ENCRYPTION | SCHEMABINDING | VIEW_METADATA} [,...n]]
AS
    select_statement
    [WITH CHECK OPTION]
```

### Rules
- Max 1024 columns.
- Cannot contain: ORDER BY (unless TOP/OFFSET), INTO, OPTION, temp table references.
- SCHEMABINDING: prevents base table modifications. Required for indexed views.
- WITH CHECK OPTION: ensures modifications remain visible through view.
- Nested views: max 32 levels.

### Updatable Views
- Single base table in modifiable portion.
- No aggregates, GROUP BY, HAVING, DISTINCT, UNION, TOP, OFFSET.
- Columns not in view must allow NULL or have DEFAULT.

## 6. CREATE PROCEDURE

```sql
CREATE [OR ALTER] {PROC|PROCEDURE} [schema.]proc_name
    [{@param type [= default] [OUT|OUTPUT|READONLY]} [,...n]]
    [WITH {ENCRYPTION | RECOMPILE | EXECUTE AS clause}]
AS
BEGIN
    sql_statements
END
```

### Rules
- Max 2100 parameters.
- OUTPUT: bidirectional parameter. READONLY: for table-valued parameters.
- Default values: caller can omit parameter.
- Temp procedures: #name (session), ##name (global).
- SET options revert when procedure returns.
- RETURN [int]: exit with return code (0 = success convention).
- Max nesting: 32 levels.

## 7. CREATE FUNCTION

### Scalar Function
```sql
CREATE [OR ALTER] FUNCTION [schema.]func_name
    ([{@param type [= default] [READONLY]} [,...n]])
RETURNS return_data_type
    [WITH {SCHEMABINDING | RETURNS NULL ON NULL INPUT | CALLED ON NULL INPUT | INLINE = {ON|OFF}}]
AS
BEGIN
    function_body
    RETURN scalar_expression
END
```

### Inline Table-Valued Function
```sql
CREATE FUNCTION [schema.]func_name (...)
RETURNS TABLE
AS
RETURN [(] select_statement [)]
```

### Multi-Statement Table-Valued Function
```sql
CREATE FUNCTION [schema.]func_name (...)
RETURNS @var TABLE (column_defs...)
AS
BEGIN
    function_body
    RETURN
END
```

### Rules
- RETURNS NULL ON NULL INPUT: short-circuit on NULL parameters.
- CALLED ON NULL INPUT (default): body executes with NULLs.
- **Cannot produce side effects:** no INSERT/UPDATE/DELETE on base tables. Table variables only.
- No dynamic SQL, TRY/CATCH, temp tables, cursors that modify data.
- Max 2100 parameters.
- Scalar functions in WHERE severely impact performance (row-by-row evaluation).
- Inline TVFs: optimizer can inline (best performance).

## 8. CREATE TRIGGER

### DML Trigger
```sql
CREATE [OR ALTER] TRIGGER [schema.]trigger_name
ON {table | view}
    [WITH {ENCRYPTION | EXECUTE AS clause}]
{FOR | AFTER | INSTEAD OF} {[INSERT] [,] [UPDATE] [,] [DELETE]}
AS
    sql_statements
```

### DDL Trigger
```sql
CREATE TRIGGER trigger_name
ON {ALL SERVER | DATABASE}
{FOR | AFTER} {event_type | event_group} [,...n]
AS
    sql_statements
```

### Rules
- FOR = AFTER synonym. AFTER fires after statement succeeds (after constraints).
- INSTEAD OF: replaces the operation. Max one per INSERT/UPDATE/DELETE per table.
- Multiple AFTER triggers per event allowed (sp_settriggerorder for ordering).
- Virtual tables: `inserted` (new rows), `deleted` (old rows).
- DDL triggers use `EVENTDATA()` XML function.
- ROLLBACK in trigger rolls back entire batch.
- Nesting: max 32 levels.
- Cannot contain: CREATE/ALTER/DROP DATABASE, RESTORE, RECONFIGURE.
- INSTEAD OF DELETE/UPDATE: not allowed with CASCADE FK actions.

## 9. CREATE DATABASE

```sql
CREATE DATABASE database_name
    [CONTAINMENT = {NONE | PARTIAL}]
    [ON [PRIMARY] (NAME=logical, FILENAME='path' [, SIZE=n] [, MAXSIZE=n] [, FILEGROWTH=n]) [,...n]
     [LOG ON (...)]
    ]
    [COLLATE collation_name]
```

- Max 128 character name. Max 32,767 databases per instance.
- Atomic: fails if any step fails.
- COLLATE: default database collation (inherits server if omitted).

## 10. CREATE SCHEMA

```sql
CREATE SCHEMA {schema_name [AUTHORIZATION owner] | AUTHORIZATION owner}
    [table_definition | view_definition | grant | revoke | deny]
```

- Atomic: all or nothing.
- Forward references allowed within same statement.
- Can create tables, views, and permissions in one statement.

## 11. Permission Statements

### GRANT
```sql
GRANT {ALL | permission [(column)]} [ON [class::] securable]
    TO principal [,...n] [WITH GRANT OPTION] [AS principal]
```
- WITH GRANT OPTION: allows re-granting.
- Removes DENY on same permission.

### DENY
```sql
DENY {ALL | permission} [ON [class::] securable]
    TO principal [,...n] [CASCADE] [AS principal]
```
- Takes precedence over GRANT (except sysadmin and object owners).
- CASCADE: propagates to downstream grantees.

### REVOKE
```sql
REVOKE [GRANT OPTION FOR] {ALL | permission} [ON [class::] securable]
    {TO|FROM} principal [,...n] [CASCADE] [AS principal]
```
- Removes both GRANT and DENY entries.
- GRANT OPTION FOR: revokes re-grant ability only.

### Permission Hierarchy
```
Server → Database → Schema → Object (Table/View/Proc/Function) → Column
```
CONTROL at any level implies all permissions below.
