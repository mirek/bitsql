# IR design

The bound IR is dialect-neutral: every dialect decision is resolved by the
binder and materialized as an explicit node, so the executor never asks which
dialect it serves.

What the binder materializes:

- Implicit conversions become explicit `Cast` nodes, following T-SQL type
  precedence.
- Comparisons carry their collation, e.g. `Cmp(Eq, a, b, Some(Latin1_General_CI_AS))`.
- Functions resolve to concrete IDs (`LEN` → `fn_len_trim_trailing`).
- `TOP`, `LIMIT` and `OFFSET … FETCH` lower to one `Limit`. `OUTPUT` and
  `RETURNING` lower to one returning clause.
- Views and computed columns are inlined as subplans and expressions.
- Isolation level and table hints become a `LockSpec` on each `Scan` and DML node.
- Result column metadata (type, precision/scale, nullability, collation) is
  computed by the binder, never from runtime values: COLMETADATA must be exact
  even for empty or all-NULL results.

```moonbit
enum SqlType {
  Bit; TinyInt; SmallInt; Int; BigInt; Decimal(Int, Int)
  NVarChar(Int?); VarChar(Int?)
  DateTime2(Int); DateTimeOffset(Int)
  UniqueIdentifier; RowVersion
}

enum Expr {
  Col(Int)                            // resolved column index
  Lit(Value)
  Var(Int)                            // resolved scope variable
  Cast(Expr, SqlType)                 // inserted by binder
  Cmp(CmpOp, Expr, Expr, Collation?)
  Call(FnId, Array[Expr])             // resolved via Semantics
  Case(Array[(Expr, Expr)], Expr?)
  Subquery(Plan)
}

enum Plan {
  Scan(TableId, Access, LockSpec?)    // Access = FullScan | Seek(IndexId, Interval)
  Filter(Plan, Expr)
  Project(Plan, Array[Expr])
  Join(JoinKind, Plan, Plan, Expr)
  Aggregate(Plan, Array[Expr], Array[AggCall])
  Sort(Plan, Array[SortKey])
  Limit(Plan, Int64?, Int64)          // TOP / LIMIT / OFFSET-FETCH
  Values(Array[Array[Expr]])
  TableFunction(FnId, Array[Expr], Schema)  // OPENJSON, STRING_SPLIT
}

enum Stmt {
  Query(Plan)
  Insert(TableId, Plan, Array[Expr]?) // OUTPUT
  Update(TableId, Plan, Array[(Int, Expr)], Array[Expr]?)
  Delete(TableId, Plan, Array[Expr]?)
  Merge(MergeSpec)
  Declare(Int, SqlType, Expr?)
  Set(Int, Expr)
  If(Expr, Array[Stmt], Array[Stmt])
  While(Expr, Array[Stmt])
  TryCatch(Array[Stmt], Array[Stmt])
  Exec(ProcId, Array[Expr])
  ExecDynamic(Expr, Array[Param])     // sp_executesql
  CursorOp(CursorOp)
  Throw(Expr?, Expr?, Expr?)
  Begin; Commit; Rollback
  Ddl(DdlStmt)
}
```

These sketches are the target shape; the real definitions live in
`src/core/ir` and win when they differ. Update this page when the shape changes
materially.

## Semantics record

A dialect is a parser plus a record of functions rather than a class hierarchy.
One shared binder takes the record as a parameter:

```moonbit
struct Semantics {
  coerce : (SqlType, SqlType) -> SqlType?
  default_collation : Collation
  resolve_fn : (String, Array[SqlType]) -> FnId?
  classify_error : (Int) -> ErrorClass
  catalog_views : Map[String, VirtualTable]
}
```

A MySQL dialect can start as `{ ..tsql, coerce: mysql_coerce }` and diverge
piece by piece.
