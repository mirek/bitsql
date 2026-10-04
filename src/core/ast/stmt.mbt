///|
pub(all) struct Stmt {
  kind : StmtKind
  span : Span
} derive(Eq, Debug)

///|
pub(all) enum CreateMode {
  Create
  Alter
  CreateOrAlter
} derive(Eq, Debug)

///|
pub(all) enum StmtKind {
  Select(Query)
  Insert(Insert)
  Update(Update)
  Delete(Delete)
  Merge(Merge)
  Truncate(ObjectName)
  /// `INSERT BULK t (col type, ...) [WITH (option, ...)]`: announces a TDS
  /// BulkLoad message (tedious newBulkLoad / mssql request.bulk).
  InsertBulk(ObjectName, Array[(Ident, TypeName)], Array[String])
  CreateTable(CreateTable)
  AlterTable(ObjectName, AlterTableAction)
  /// `ENABLE|DISABLE TRIGGER ALL|names ON table` (table None for `ON
  /// DATABASE` / `ON ALL SERVER`); empty names means ALL.
  EnableTrigger(enable~ : Bool, Array[Ident], ObjectName?)
  CreateIndex(CreateIndex)
  /// `DROP INDEX ix ON t` (table Some) or legacy `DROP INDEX t.ix` (None).
  /// Items: (index, table, has WITH options).
  DropIndex(if_exists~ : Bool, Array[(ObjectName, ObjectName?, Bool)])
  CreateView(CreateView)
  CreateProcedure(CreateProcedure)
  CreateFunction(CreateFunction)
  CreateTrigger(CreateTrigger)
  CreateSchema(Ident, authorization~ : Ident?)
  CreateType(CreateType)
  /// `CREATE SYNONYM name FOR base_object`.
  CreateSynonym(ObjectName, ObjectName)
  CreateSequence(ObjectName, type_~ : TypeName?, options~ : Array[String])
  /// ALTER SEQUENCE name options (see `CreateSequence`; adds `RESTART`).
  AlterSequence(ObjectName, Array[String])
  /// DROP TABLE / VIEW / PROCEDURE / FUNCTION / TRIGGER / SCHEMA / TYPE /
  /// SEQUENCE.
  Drop(DropKind, if_exists~ : Bool, Array[ObjectName])
  Permission(Permission)
  Declare(Array[DeclareVar])
  DeclareTable(String, TableBody)
  DeclareCursor(Cursor)
  /// `SET @v = CURSOR ... FOR query` (the cursor's name is the variable's).
  SetCursor(Cursor)
  SetVar(String, AssignOp, Expr)
  /// `SET @x.modify('xml dml')`: an xml mutator method on a variable.
  SetVarMethod(String, Ident, Array[Expr])
  SetOption(Array[String], SetValue)
  SetIdentityInsert(ObjectName, Bool)
  /// Upper-cased level: `READ COMMITTED`, `SNAPSHOT`, ...
  SetIsolation(String)
  If(Expr, Stmt, Stmt?)
  While(Expr, Stmt)
  Block(Array[Stmt])
  TryCatch(Array[Stmt], Array[Stmt])
  Break
  Continue
  Return(Expr?)
  Goto(Ident)
  Label(Ident)
  /// `WAITFOR DELAY|TIME expr` (parse only).
  WaitFor(String, Expr)
  /// Re-throw when `args` is empty, else number, message, state.
  Throw(Array[Expr])
  RaisError(Array[Expr], options~ : Array[String])
  Print(Expr)
  Exec(Exec)
  /// `EXEC (@sql + N'...')`; parts are concatenated.
  ExecString(Array[Expr])
  BeginTran(name~ : Expr?, distributed~ : Bool)
  Commit(name~ : Expr?)
  Rollback(name~ : Expr?)
  Save(name~ : Expr?)
  OpenCursor(Ident, global~ : Bool)
  Fetch(Fetch)
  CloseCursor(Ident, global~ : Bool)
  Deallocate(Ident, global~ : Bool)
  Use(Ident)
  /// `CREATE DATABASE name [COLLATE c] [...]`; file/option clauses are
  /// accepted and ignored (memory-only engine).
  CreateDatabase(Ident, collate~ : Ident?)
} derive(Eq, Debug)

///|
pub(all) enum DropKind {
  DropTable
  DropView
  DropProcedure
  DropFunction
  DropTrigger
  DropSchema
  DropType
  DropSequence
  DropSynonym
  DropDatabase
} derive(Eq, Debug)

///|
pub(all) struct OutputClause {
  items : Array[SelectItem]
  /// `INTO target (columns)`
  into : (TableRef, Array[Ident])?
  span : Span
} derive(Eq, Debug)

///|
pub(all) enum InsertSource {
  InsertValues(Array[Array[Expr]])
  InsertQuery(Query)
  InsertExec(Exec)
  DefaultValues
} derive(Eq, Debug)

///|
pub(all) struct Insert {
  ctes : Array[Cte]
  top : Top?
  target : TableRef
  columns : Array[Ident]
  output : Array[OutputClause]
  source : InsertSource
  options : Array[QueryHint]
} derive(Eq, Debug)

///|
pub(all) enum SetTarget {
  /// `col` / `t.col`
  SetColumn(Array[Ident])
  /// `@v`
  SetVariable(String)
  /// `@v = col = expr`
  SetVarColumn(String, Array[Ident])
} derive(Eq, Debug)

///|
pub(all) struct SetClause {
  target : SetTarget
  op : AssignOp
  value : Expr
  span : Span
} derive(Eq, Debug)

///|
pub(all) struct Update {
  ctes : Array[Cte]
  top : Top?
  target : TableRef
  sets : Array[SetClause]
  output : Array[OutputClause]
  from : Array[TableRef]
  where_ : Expr?
  /// `WHERE CURRENT OF [GLOBAL] cursor`
  current_of : Ident?
  current_of_global : Bool
  options : Array[QueryHint]
} derive(Eq, Debug)

///|
pub(all) struct Delete {
  ctes : Array[Cte]
  top : Top?
  target : TableRef
  output : Array[OutputClause]
  from : Array[TableRef]
  where_ : Expr?
  current_of : Ident?
  current_of_global : Bool
  options : Array[QueryHint]
} derive(Eq, Debug)

///|
pub(all) enum MergeMatch {
  Matched
  NotMatchedByTarget
  NotMatchedBySource
} derive(Eq, Debug)

///|
pub(all) enum MergeAction {
  MergeUpdate(Array[SetClause])
  MergeDelete
  /// Empty `values` with `default_values` set is `INSERT DEFAULT VALUES`.
  MergeInsert(
    columns~ : Array[Ident],
    values~ : Array[Expr],
    default_values~ : Bool
  )
} derive(Eq, Debug)

///|
pub(all) struct MergeWhen {
  match_ : MergeMatch
  condition : Expr?
  action : MergeAction
  span : Span
} derive(Eq, Debug)

///|
pub(all) struct Merge {
  ctes : Array[Cte]
  top : Top?
  target : TableRef
  source : TableRef
  on : Expr
  whens : Array[MergeWhen]
  output : Array[OutputClause]
  options : Array[QueryHint]
} derive(Eq, Debug)

///|
pub(all) struct Identity {
  seed : String?
  increment : String?
} derive(Eq, Debug)

///|
pub(all) enum RefAction {
  NoAction
  Cascade
  SetNull
  SetDefault
} derive(Eq, Debug)

///|
pub(all) struct ForeignRef {
  table : ObjectName
  columns : Array[Ident]
  on_delete : RefAction?
  on_update : RefAction?
  not_for_replication : Bool
} derive(Eq, Debug)

///|
pub(all) struct IndexColumn {
  name : Ident
  desc : Bool
} derive(Eq, Debug)

///|
/// `name = value` option (index / table / constraint WITH (...)), upper-cased
/// name, value as raw text.
pub(all) struct OptionKV {
  name : String
  value : String?
} derive(Eq, Debug)

///|
pub(all) enum ColumnConstraintKind {
  ColPrimaryKey(clustered~ : Bool?, options~ : Array[OptionKV])
  ColUnique(clustered~ : Bool?, options~ : Array[OptionKV])
  ColCheck(Expr, not_for_replication~ : Bool)
  ColDefault(Expr)
  ColReferences(ForeignRef)
} derive(Eq, Debug)

///|
pub(all) struct ColumnConstraint {
  name : Ident?
  kind : ColumnConstraintKind
  span : Span
} derive(Eq, Debug)

///|
/// Column definition. Computed columns have `type_ == None` and
/// `computed == Some(expr)`. `nullable` is `None` when not written.
pub(all) struct ColumnDef {
  name : Ident
  type_ : TypeName?
  computed : Expr?
  persisted : Bool
  collate : Ident?
  nullable : Bool?
  identity : Identity?
  rowguidcol : Bool
  sparse : Bool
  constraints : Array[ColumnConstraint]
  span : Span
} derive(Eq, Debug)

///|
pub(all) enum TableConstraintKind {
  PrimaryKey(clustered~ : Bool?, Array[IndexColumn], options~ : Array[OptionKV])
  Unique(clustered~ : Bool?, Array[IndexColumn], options~ : Array[OptionKV])
  ForeignKey(Array[Ident], ForeignRef)
  Check(Expr, not_for_replication~ : Bool)
  /// `DEFAULT expr FOR column` (ALTER TABLE ... ADD CONSTRAINT).
  DefaultFor(Expr, Ident)
} derive(Eq, Debug)

///|
pub(all) struct TableConstraint {
  name : Ident?
  kind : TableConstraintKind
  span : Span
} derive(Eq, Debug)

///|
/// Column and table-constraint list shared by CREATE TABLE, table variables,
/// table types and multi-statement TVF return tables.
pub(all) struct TableBody {
  columns : Array[ColumnDef]
  constraints : Array[TableConstraint]
  /// Inline `INDEX ix (cols)` definitions (parse only).
  indexes : Array[(Ident, Array[IndexColumn])]
} derive(Eq, Debug)

///|
pub(all) struct CreateTable {
  name : ObjectName
  body : TableBody
  on_filegroup : Ident?
  options : Array[OptionKV]
} derive(Eq, Debug)

///|
pub(all) enum AlterTableAction {
  /// `[WITH CHECK|NOCHECK] ADD ...`
  Add(TableBody, with_check~ : Bool?)
  AlterColumn(
    Ident,
    TypeName,
    collate~ : Ident?,
    nullable~ : Bool?,
    options~ : Array[String]
  )
  /// Items are (is_column, if_exists, name).
  DropItems(Array[(Bool, Bool, Ident)])
  /// `[WITH CHECK|NOCHECK] CHECK|NOCHECK CONSTRAINT ALL|names`; empty names
  /// means ALL.
  CheckConstraints(enable~ : Bool, Array[Ident], with_check~ : Bool?)
  /// `ENABLE|DISABLE TRIGGER ALL|names`; empty names means ALL.
  EnableTriggers(enable~ : Bool, Array[Ident])
  SetOptions(Array[OptionKV])
} derive(Eq, Debug)

///|
pub(all) struct CreateIndex {
  unique : Bool
  clustered : Bool?
  columnstore : Bool
  name : Ident
  table : ObjectName
  columns : Array[IndexColumn]
  included : Array[Ident]
  where_ : Expr?
  options : Array[OptionKV]
  on_filegroup : Ident?
} derive(Eq, Debug)

///|
pub(all) struct CreateView {
  mode : CreateMode
  name : ObjectName
  columns : Array[Ident]
  /// Upper-cased `WITH` attributes (`SCHEMABINDING`, ...).
  attributes : Array[String]
  query : Query
  check_option : Bool
  /// Source text of the whole CREATE statement.
  definition : String
} derive(Eq, Debug)

///|
pub(all) struct Param {
  name : String
  type_ : TypeName
  varying : Bool
  default_ : Expr?
  output : Bool
  read_only : Bool
  span : Span
} derive(Eq, Debug)

///|
pub(all) struct CreateProcedure {
  mode : CreateMode
  name : ObjectName
  params : Array[Param]
  /// Upper-cased `WITH` options (`RECOMPILE`, `EXECUTE AS OWNER`, ...).
  options : Array[String]
  body : Array[Stmt]
  definition : String
} derive(Eq, Debug)

///|
pub(all) enum FuncReturns {
  Scalar(TypeName, Array[Stmt])
  InlineTable(Query)
  /// Multi-statement TVF: `RETURNS @t TABLE (...) AS BEGIN ... END`.
  TableVariable(String, TableBody, Array[Stmt])
} derive(Eq, Debug)

///|
pub(all) struct CreateFunction {
  mode : CreateMode
  name : ObjectName
  params : Array[Param]
  returns : FuncReturns
  options : Array[String]
  definition : String
} derive(Eq, Debug)

///|
pub(all) enum TriggerTiming {
  After
  /// `FOR` is a synonym of AFTER; kept distinct for fidelity of definitions.
  For
  InsteadOf
} derive(Eq, Debug)

///|
pub(all) enum DmlEvent {
  OnInsert
  OnUpdate
  OnDelete
} derive(Eq, Debug)

///|
pub(all) struct CreateTrigger {
  mode : CreateMode
  name : ObjectName
  table : ObjectName
  timing : TriggerTiming
  events : Array[DmlEvent]
  options : Array[String]
  not_for_replication : Bool
  body : Array[Stmt]
  definition : String
} derive(Eq, Debug)

///|
/// `CREATE TYPE n FROM base [NULL|NOT NULL]` or `CREATE TYPE n AS TABLE (...)`.
pub(all) struct CreateType {
  name : ObjectName
  base : TypeName?
  nullable : Bool?
  table : TableBody?
} derive(Eq, Debug)

///|
pub(all) enum PermissionAction {
  Grant
  Deny
  Revoke
} derive(Eq, Debug)

///|
/// GRANT / DENY / REVOKE, parse only. Permissions are upper-cased words
/// (`SELECT`, `VIEW DEFINITION`).
pub(all) struct Permission {
  action : PermissionAction
  permissions : Array[String]
  /// `ON [class::]securable`
  on_class : String?
  on : ObjectName?
  columns : Array[Ident]
  principals : Array[Ident]
  grant_option : Bool
  cascade : Bool
} derive(Eq, Debug)

///|
pub(all) struct DeclareVar {
  name : String
  type_ : TypeName
  init : Expr?
  span : Span
} derive(Eq, Debug)

///|
pub(all) struct Cursor {
  name : Ident
  /// Upper-cased options in source order (`LOCAL`, `STATIC`, `READ_ONLY`,
  /// ISO `INSENSITIVE` / `SCROLL`, `READ ONLY` from `FOR READ ONLY`).
  options : Array[String]
  query : Query
  for_update : Bool
  update_columns : Array[Ident]
  /// ISO syntax (`[INSENSITIVE] [SCROLL] CURSOR FOR`): its options come
  /// first in `options`, followed by any (invalid, 1049) T-SQL ones.
  iso : Bool
} derive(Eq, Debug)

///|
pub(all) enum SetValue {
  On
  Off
  /// Bare word such as `mdy`, `us_english`, `LOW`.
  Word(String)
  ValueExpr(Expr)
} derive(Eq, Debug)

///|
pub(all) struct ExecArg {
  name : String?
  /// DEFAULT is `ExprKind::Default`; a bare word is `Column([word])`.
  value : Expr
  output : Bool
  span : Span
} derive(Eq, Debug)

///|
pub(all) enum ExecTarget {
  ExecProc(ObjectName)
  /// `EXEC @proc_name_var`
  ExecVar(String)
} derive(Eq, Debug)

///|
pub(all) struct Exec {
  return_var : String?
  target : ExecTarget
  args : Array[ExecArg]
  with_recompile : Bool
} derive(Eq, Debug)

///|
pub(all) enum FetchOrientation {
  Next
  Prior
  First
  Last
  Absolute(Expr)
  Relative(Expr)
} derive(Eq, Debug)

///|
pub(all) struct Fetch {
  orientation : FetchOrientation
  cursor : Ident
  global : Bool
  into : Array[String]
} derive(Eq, Debug)
