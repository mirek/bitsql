# T-SQL Transactions and Error Handling

## 1. Transaction Modes

| Mode | Description |
|------|-------------|
| Autocommit | Each statement is its own transaction (default). |
| Explicit | BEGIN TRANSACTION ... COMMIT/ROLLBACK. |
| Implicit | New transaction auto-starts after prior completes; must explicitly COMMIT/ROLLBACK. |

## 2. BEGIN TRANSACTION

```sql
BEGIN {TRAN | TRANSACTION}
    [transaction_name | @tran_name_variable]
    [WITH MARK ['description']]
```

- Increments @@TRANCOUNT by 1.
- Names meaningful only on outermost pair; inner names ignored.
- Names: max 32 chars, always case-sensitive.
- Nested BEGIN TRAN: increments @@TRANCOUNT but inner transactions are not independently manageable.

## 3. COMMIT TRANSACTION

```sql
COMMIT [{TRAN | TRANSACTION} [name]]
    [WITH (DELAYED_DURABILITY = {OFF | ON})]
```

- @@TRANCOUNT = 1: makes all modifications permanent, decrements to 0.
- @@TRANCOUNT > 1: decrements by 1 only. Transaction stays active. Nothing committed.
- @@TRANCOUNT = 0: error.
- Transaction name is ignored by engine (documentation only).
- Cannot rollback after COMMIT when @@TRANCOUNT reaches 0.

## 4. ROLLBACK TRANSACTION

```sql
ROLLBACK {TRAN | TRANSACTION}
    [transaction_name | savepoint_name | @variable]
```

- Without name: rolls back to outermost BEGIN TRAN. Sets @@TRANCOUNT to 0.
- With transaction name: must be outermost. Rolls back everything. @@TRANCOUNT = 0.
- With savepoint name: rolls back to savepoint. **Does NOT change @@TRANCOUNT.**
- Local variables and table variables: NOT erased by ROLLBACK.
- Duplicate savepoint names: rolls back to most recent.

## 5. SAVE TRANSACTION

```sql
SAVE {TRAN | TRANSACTION} {savepoint_name | @variable}
```

- Creates bookmark within transaction for partial rollback.
- Names: max 32 chars, case-sensitive.
- Duplicate names allowed.
- Transaction must still be committed or fully rolled back after partial rollback to savepoint.

## 6. @@TRANCOUNT Tracking

| Action | Effect |
|--------|--------|
| BEGIN TRAN | +1 |
| COMMIT | -1 |
| ROLLBACK (no savepoint) | → 0 |
| ROLLBACK TO savepoint | No change |

## 7. XACT_STATE()

| Return | Meaning |
|--------|---------|
| 1 | Active committable transaction |
| -1 | Active uncommittable transaction (must ROLLBACK) |
| 0 | No active transaction |

## 8. TRY...CATCH

```sql
BEGIN TRY
    { sql_statement | statement_block }
END TRY
BEGIN CATCH
    [{ sql_statement | statement_block }]
END CATCH
```

### Rules
- Catches errors with severity > 10 that don't close the connection.
- END TRY must be immediately followed by BEGIN CATCH.
- Can be nested. TRY or CATCH can contain nested TRY...CATCH.
- Cannot span batches or BEGIN...END blocks.
- Cannot be used in user-defined functions.
- GOTO cannot enter TRY/CATCH from outside (can jump within or exit).

### Errors NOT Caught at Same Execution Level
- Compile/syntax errors preventing batch execution.
- Statement-level recompilation errors.
- Severity <= 10 (informational).
- Severity >= 20 (connection-terminating).
- BUT: caught if from lower execution level (sp_executesql, called procedure).

### Error Functions (CATCH scope only)

| Function | Return | Description |
|----------|--------|-------------|
| ERROR_NUMBER() | int | Error number |
| ERROR_SEVERITY() | int | Severity (0-25) |
| ERROR_STATE() | int | Error state |
| ERROR_LINE() | int | Line number |
| ERROR_PROCEDURE() | nvarchar(128) | Procedure/trigger name (NULL if outside) |
| ERROR_MESSAGE() | nvarchar(4000) | Full message with substitutions |

All return NULL outside CATCH block.

### Uncommittable Transactions
- Error in TRY can make transaction uncommittable (XACT_STATE() = -1).
- Only reads and ROLLBACK allowed.
- Auto-rolled back when batch finishes.

## 9. THROW

```sql
THROW [error_number, message, state]
```

### With Parameters
- error_number: int, >= 50000 and <= 2147483647.
- message: nvarchar(2048). `%` must be doubled (`%%`).
- state: tinyint, 0-255.
- Severity is always 16.
- error_number does NOT need to be in sys.messages.

### Without Parameters (bare THROW)
- Must be inside CATCH block.
- Re-raises caught exception with original severity.
- Statement before THROW must end with `;`.

### vs RAISERROR
| Feature | THROW | RAISERROR |
|---------|-------|-----------|
| Severity | Always 16 | Configurable 0-25 |
| sys.messages | Not required | msg_id must exist |
| XACT_ABORT | Honored | Not honored |
| Format strings | No (use FORMATMESSAGE) | printf-style (%d, %s) |
| Terminates batch | Yes (if no TRY...CATCH) | Only severity >= 20 |

## 10. RAISERROR

```sql
RAISERROR ({msg_id | msg_str | @var}, severity, state [, args...])
    [WITH {LOG | NOWAIT | SETERROR}]
```

### Parameters
- msg_id: user message from sys.messages (> 50000 for user-defined).
- msg_str: ad hoc with printf format (%d, %s, %i, %o, %u, %x, %X). Max 2047 chars.
- severity: 0-25. 19-25 require WITH LOG. 20-25 terminate connection.
- state: 0-255.

### Format Specifiers
`%[flag][width][.precision][{h|l}]type`
- Flags: `-` left-justify, `+` sign, `0` zero-pad, `#` hex prefix.
- Types: `d`/`i` signed int, `s` string, `u` unsigned, `x`/`X` hex.
- `%I64d` for bigint.

### WITH Options
- LOG: write to error log.
- NOWAIT: send message immediately.
- SETERROR: set @@ERROR regardless of severity.

### TRY...CATCH Interaction
- Severity 11-19 in TRY: transfers to CATCH.
- Severity <= 10: does NOT invoke CATCH (informational).
- Severity >= 20: terminates connection.

## 11. SET Statements

### Key Session Settings

| Statement | Default | Behavior |
|-----------|---------|----------|
| SET ANSI_NULLS ON/OFF | ON | ON: `=NULL` → UNKNOWN. OFF: `=NULL` → TRUE for NULLs. |
| SET QUOTED_IDENTIFIER ON/OFF | ON | ON: `"x"` = identifier. OFF: `"x"` = string. |
| SET NOCOUNT ON/OFF | OFF | ON: suppress "n rows affected". Does NOT affect @@ROWCOUNT. |
| SET XACT_ABORT ON/OFF | OFF | ON: any error auto-rollbacks transaction. |
| SET IDENTITY_INSERT tbl ON/OFF | OFF | ON: allow explicit IDENTITY values. One table per session. |
| SET ARITHABORT ON/OFF | ON | ON: overflow/divide-by-zero terminates. OFF: NULL with warning. |
| SET ANSI_PADDING ON/OFF | ON | ON: trailing blanks preserved. OFF: trimmed for char/varchar. |
| SET ANSI_WARNINGS ON/OFF | ON | ON: aggregate NULL warnings, divide-by-zero error. |
| SET CONCAT_NULL_YIELDS_NULL ON/OFF | ON | ON: string + NULL = NULL. OFF: string + NULL = string. |
| SET NUMERIC_ROUNDABORT ON/OFF | OFF | ON: error on precision loss. OFF: round silently. |
| SET ROWCOUNT n | 0 | Limit rows affected. Deprecated for DML; use TOP. |
| SET IMPLICIT_TRANSACTIONS ON/OFF | OFF | ON: auto-start transaction on SELECT/INSERT/UPDATE/DELETE/etc. |
| SET DATEFIRST n | 7 (Sunday) | First day of week (1=Monday ... 7=Sunday). |
| SET DATEFORMAT fmt | mdy | Date input format: mdy, dmy, ymd, ydm, myd, dym. |
| SET DEADLOCK_PRIORITY {LOW/NORMAL/HIGH/n} | NORMAL | n: -10 to 10. Lower = more likely deadlock victim. |
| SET LOCK_TIMEOUT n | -1 | ms to wait for lock. -1=forever, 0=no wait. |
| SET TEXTSIZE n | varies | Max bytes for text/ntext/image. 0=4KB. |
| SET TRANSACTION ISOLATION LEVEL level | READ COMMITTED | See below. |

### Required SET Options for Indexed Views / Computed Column Indexes

All must be ON: ARITHABORT, CONCAT_NULL_YIELDS_NULL, QUOTED_IDENTIFIER, ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS.
Must be OFF: NUMERIC_ROUNDABORT.

### SET in Stored Procedure/Trigger
- Automatically restored to previous value on return.

## 12. Transaction Isolation Levels

```sql
SET TRANSACTION ISOLATION LEVEL
    { READ UNCOMMITTED | READ COMMITTED | REPEATABLE READ | SERIALIZABLE | SNAPSHOT }
```

| Level | Dirty Reads | Non-Repeatable | Phantoms |
|-------|-------------|----------------|----------|
| READ UNCOMMITTED | Yes | Yes | Yes |
| READ COMMITTED (default) | No | Yes | Yes |
| REPEATABLE READ | No | No | Yes |
| SERIALIZABLE | No | No | No |
| SNAPSHOT | No | No | No (via versioning) |

## 13. Implementation Notes

### Transaction Stack
- Maintain @@TRANCOUNT counter.
- Only outermost COMMIT persists changes.
- ROLLBACK to savepoint: no @@TRANCOUNT change, partial undo.

### Error Handling Stack
- Stack of TRY...CATCH contexts.
- ERROR_* functions scoped to current CATCH.
- XACT_STATE() tracks committability.
- THROW without params: re-raise from CATCH.
- RAISERROR severity <= 10: informational, no CATCH.

### Cursor Behavior on ROLLBACK
- CURSOR_CLOSE_ON_COMMIT ON: closes but doesn't deallocate.
- CURSOR_CLOSE_ON_COMMIT OFF: doesn't affect STATIC/INSENSITIVE cursors.
