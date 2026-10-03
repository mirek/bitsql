///|
pub(all) struct Identity {
  seed : Int64
  increment : Int64
} derive(Debug, Eq)

///|
/// Column definition. Default and computed expressions are kept as SQL text
/// (re-parsed by the binder, like SQL Server's sys.default_constraints /
/// sys.computed_columns definitions).
pub(all) struct Column {
  name : String
  ty : @types.SqlType
  nullable : Bool
  identity : Identity?
  default_ : String?
  default_name : String?
  computed : String?
  persisted : Bool
  rowguidcol : Bool
} derive(Debug)

///|
pub(all) struct Index {
  name : String
  unique : Bool
  primary : Bool
  clustered : Bool
  /// (column ordinal, descending)
  columns : Array[(Int, Bool)]
  /// Filtered index predicate text.
  filter : String?
  /// Constraint (PK/UNIQUE) rather than CREATE INDEX.
  is_constraint : Bool
} derive(Debug)

///|
pub(all) struct Check {
  name : String
  expr : String
  enabled : Bool
} derive(Debug)

///|
pub(all) enum RefAction {
  NoAction
  Cascade
  SetNull
  SetDefault
} derive(Debug, Eq)

///|
pub(all) struct ForeignKey {
  name : String
  columns : Array[Int]
  ref_table : Int // object id
  ref_columns : Array[Int]
  on_delete : RefAction
  on_update : RefAction
  enabled : Bool
} derive(Debug)

///|
pub(all) enum ObjectKind {
  UserTable
  View
  Procedure
  ScalarFunction
  TableFunction
  Trigger
} derive(Debug, Eq)

///|
pub(all) struct Table {
  id : Int
  schema : String
  name : String
  columns : Array[Column]
  indexes : Array[Index]
  checks : Array[Check]
  foreign_keys : Array[ForeignKey]
  /// Unix-epoch-free creation stamp (ticks), for sys.objects.create_date.
  created : Int64
} derive(Debug)

///|
pub fn Table::column_index(self : Table, name : String) -> Int? {
  let n = name.to_lower()
  for i, c in self.columns {
    if c.name.to_lower() == n {
      return Some(i)
    }
  }
  None
}

///|
pub fn Table::primary_key(self : Table) -> Index? {
  for i in self.indexes {
    if i.primary {
      return Some(i)
    }
  }
  None
}

///|
/// Non-table schema objects (views, procedures, functions, triggers) are
/// kept as definitions; the session parses and binds them on use.
pub(all) struct Module {
  id : Int
  schema : String
  name : String
  kind : ObjectKind
  definition : String
  /// Parent table for triggers.
  parent : Int?
  created : Int64
} derive(Debug)
