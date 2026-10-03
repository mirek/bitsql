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
  /// sys.columns.column_id: stable, never reused after DROP COLUMN.
  column_id : Int
  name : String
  ty : @types.SqlType
  nullable : Bool
  identity : Identity?
  default_ : String?
  default_name : String?
  /// Object id of the DEFAULT constraint (0 when there is none).
  default_id : Int
  /// The DEFAULT constraint name was generated (is_system_named).
  default_auto : Bool
  computed : String?
  persisted : Bool
  rowguidcol : Bool
} derive(Debug)

///|
pub(all) struct Index {
  /// sys.indexes.index_id: 1 = clustered, 2.. nonclustered (not reused).
  index_id : Int
  /// Object id of the PK/UNIQUE constraint (0 for CREATE INDEX).
  object_id : Int
  name : String
  /// The constraint name was generated (is_system_named).
  auto_named : Bool
  unique : Bool
  primary : Bool
  clustered : Bool
  /// (column ordinal, descending)
  columns : Array[(Int, Bool)]
  /// INCLUDE columns (ordinals).
  included : Array[Int]
  /// Filtered index predicate text.
  filter : String?
  /// Filtered index of the form `c IS NOT NULL [AND ...]`: rows with NULL
  /// in any of these columns (ordinals) are not in the index.
  not_null_filter : Array[Int]
  /// Constraint (PK/UNIQUE) rather than CREATE INDEX.
  is_constraint : Bool
} derive(Debug)

///|
pub(all) struct Check {
  id : Int
  name : String
  expr : String
  enabled : Bool
  /// Rows were not validated (WITH NOCHECK, or re-enabled without CHECK).
  not_trusted : Bool
  /// Column-level CHECK: the column's column_id (parent_column_id), else 0.
  column_id : Int
  auto_named : Bool
  not_for_replication : Bool
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
  id : Int
  name : String
  columns : Array[Int]
  ref_table : Int // object id
  ref_columns : Array[Int]
  on_delete : RefAction
  on_update : RefAction
  enabled : Bool
  not_trusted : Bool
  auto_named : Bool
  not_for_replication : Bool
} derive(Debug)

///|
pub(all) enum ObjectKind {
  UserTable
  View
  Procedure
  ScalarFunction
  /// Inline table-valued function (IF).
  InlineFunction
  /// Multi-statement table-valued function (TF).
  TableFunction
  Trigger
  /// SO: CREATE SEQUENCE (values live in the server, not the Db).
  Sequence
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
  /// Creation stamp (100 ns ticks since 0001-01-01), sys.objects.create_date.
  created : Int64
  modified : Int64
  /// sys.tables.max_column_id_used.
  max_column_id : Int
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
  modified : Int64
  /// Triggers: DISABLE TRIGGER.
  disabled : Bool
  /// Triggers: INSTEAD OF.
  instead_of : Bool
  /// Views: result columns (empty when the binder could not derive them).
  columns : Array[Column]
  /// WITH SCHEMABINDING.
  schema_bound : Bool
  /// Views: WITH CHECK OPTION.
  check_option : Bool
  /// Scalar functions: the RETURNS type.
  returns : @types.SqlType?
} derive(Debug)

///|
/// Column by sys.columns column_id.
pub fn Table::column_by_id(self : Table, column_id : Int) -> Column? {
  for c in self.columns {
    if c.column_id == column_id {
      return Some(c)
    }
  }
  None
}

///|
/// Object type code and sys.objects type_desc of a module.
pub fn ObjectKind::code(self : ObjectKind) -> (String, String) {
  match self {
    UserTable => ("U", "USER_TABLE")
    View => ("V", "VIEW")
    Procedure => ("P", "SQL_STORED_PROCEDURE")
    ScalarFunction => ("FN", "SQL_SCALAR_FUNCTION")
    InlineFunction => ("IF", "SQL_INLINE_TABLE_VALUED_FUNCTION")
    TableFunction => ("TF", "SQL_TABLE_VALUED_FUNCTION")
    Trigger => ("TR", "SQL_TRIGGER")
    Sequence => ("SO", "SEQUENCE_OBJECT")
  }
}
