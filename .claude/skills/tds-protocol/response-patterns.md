# TDS Server Response Patterns

> Source: [MS-TDS] v20260223, Sections 2.2.4, 3.x, 4.x

## 24. Server Response Patterns

### Successful Login Response

```mermaid
graph LR
    A[ENVCHANGE<br/>Database] --> B[ENVCHANGE<br/>Language]
    B --> C[ENVCHANGE<br/>Collation]
    C --> D["INFO*"]
    D --> E[LOGINACK]
    E --> F[ENVCHANGE<br/>PacketSize]
    F --> G["FEATUREEXTACK<br/>(if negotiated)"]
    G --> H["DONE<br/>(DONE_FINAL)"]
```

```
ENVCHANGE(Database) + ENVCHANGE(Language) + ENVCHANGE(Collation) +
[INFO tokens] + LOGINACK + ENVCHANGE(PacketSize) +
[FEATUREEXTACK] + DONE(DONE_FINAL)
```

### Failed Login Response

```
ERROR + DONE(DONE_ERROR | DONE_FINAL)
```

Server may close the connection immediately after sending error for fatal auth failures.

### Query with Result Set

```mermaid
sequenceDiagram
    participant S as Server

    S->>S: COLMETADATA (column definitions)
    S->>S: ROW / NBCROW (repeated per row)
    S->>S: DONE(DONE_COUNT | DONE_FINAL)
```

```
COLMETADATA + (ROW|NBCROW)* + DONE(DONE_COUNT | DONE_FINAL)
```

### Multiple Result Sets

```mermaid
sequenceDiagram
    participant S as Server

    Note over S: Result Set 1
    S->>S: COLMETADATA + ROW*
    S->>S: DONE(DONE_MORE | DONE_COUNT)

    Note over S: Result Set 2
    S->>S: COLMETADATA + ROW*
    S->>S: DONE(DONE_FINAL | DONE_COUNT)
```

### Multi-Statement Batch (SELECT + UPDATE + SELECT)

```mermaid
sequenceDiagram
    participant S as Server

    Note over S: SELECT result
    S->>S: COLMETADATA + ROW*
    S->>S: DONE(DONE_MORE | DONE_COUNT)

    Note over S: UPDATE (no columns)
    S->>S: DONE(DONE_MORE | DONE_COUNT)

    Note over S: SELECT result
    S->>S: COLMETADATA + ROW*
    S->>S: DONE(DONE_FINAL | DONE_COUNT)
```

Note: UPDATE/INSERT/DELETE produce DONE tokens (no COLMETADATA) with DONE_COUNT = affected rows.

### Stored Procedure Execution

```mermaid
sequenceDiagram
    participant S as Server

    Note over S: Statement results within proc
    S->>S: [COLMETADATA + ROW* + DONEINPROC(DONE_COUNT)]*

    Note over S: Procedure completion
    S->>S: RETURNSTATUS(return_value)
    S->>S: DONEPROC(DONE_FINAL | DONE_COUNT)
```

```
[COLMETADATA + ROW* + DONEINPROC(DONE_COUNT)]* +
RETURNSTATUS + DONEPROC(DONE_FINAL | DONE_COUNT)
```

### Stored Procedure with OUTPUT Parameters

```
[COLMETADATA + ROW* + DONEINPROC]* +
RETURNVALUE* +
RETURNSTATUS +
DONEPROC(DONE_FINAL)
```

### Batched RPC Execution

```mermaid
sequenceDiagram
    participant C as Client
    participant S as Server

    C->>S: RPC1 + 0xFF + RPC2 + 0xFF + RPC3

    Note over S: RPC1 results
    S->>S: [result tokens] + DONEPROC(DONE_RPCINBATCH)

    Note over S: RPC2 results
    S->>S: [result tokens] + DONEPROC(DONE_RPCINBATCH)

    Note over S: RPC3 results (last)
    S->>S: [result tokens] + DONEPROC(DONE_FINAL)
```

### Error Response

```
ERROR + DONE(DONE_ERROR | DONE_FINAL)
```

### Error Within Statement Batch

```
[results for successful statements] +
ERROR + DONE(DONE_ERROR | DONE_MORE) +
[remaining statement results] +
DONE(DONE_FINAL)
```

### Transaction Begin (via TM_BEGIN_XACT)

```
ENVCHANGE(Type=8, BeginTran) + DONE(DONE_FINAL)
```

### Transaction Commit

```
ENVCHANGE(Type=9, CommitTran) + DONE(DONE_FINAL)
```

### Transaction Rollback

```
ENVCHANGE(Type=10, RollbackTran) + DONE(DONE_FINAL)
```

### Attention Acknowledgement

```mermaid
sequenceDiagram
    participant C as Client
    participant S as Server

    C->>S: SQL Batch (long query)
    S->>C: COLMETADATA + ROW + ROW...

    C->>S: Attention (0x06)
    S->>C: ...buffered ROW data...
    S->>C: DONE(DONE_ATTN)

    Note over C: Discard everything until<br/>DONE with DONE_ATTN
```

### Table Response with SESSIONSTATE

```
DONE(DONE_MORE) +
SESSIONSTATE(SeqNo, fRecoverable, StateData*) +
DONE(DONE_FINAL)
```

---

## 25. Variable-Length Data Stream Definitions

```
B_VARCHAR     = BYTELEN(1B) + *CHAR         ; length in CHARACTERS, data in UTF-16 LE
US_VARCHAR    = USHORTLEN(2B LE) + *CHAR    ; length in CHARACTERS, data in UTF-16 LE
B_VARBYTE     = BYTELEN(1B) + *BYTE         ; length in BYTES
US_VARBYTE    = USHORTLEN(2B LE) + *BYTE    ; length in BYTES
L_VARBYTE     = LONGLEN(4B LE) + *BYTE      ; length in BYTES
```

Important: B_VARCHAR and US_VARCHAR lengths are in **characters**. Multiply by 2 for byte count with UTF-16 LE encoding.
