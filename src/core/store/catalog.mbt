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
  /// Nullability in result metadata: a computed column declared PERSISTED
  /// NOT NULL is NOT NULL in sys.columns but keeps its expression's
  /// nullability on the wire (captured: msduck-runs tedious-compat-gaps
  /// #038/#039). Equal to `nullable` otherwise.
  result_nullable : Bool
  persisted : Bool
  rowguidcol : Bool
  /// user_type_id of an alias type the column was declared with (None:
  /// the system type's id).
  user_type : Int?
} derive(Debug)

///|
pub(all) struct Index {
  json : JsonIndex?
  vector : VectorIndex?
  /// sys.indexes.index_id: 1 = clustered, 2.. nonclustered (the lowest free
  /// id is reused after DROP INDEX).
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
  /// Other filter conjuncts (`c > 0`, `c IS NULL`, ...): rows failing any
  /// are not in the index.
  filter_terms : Array[FilterTerm]
  /// FILLFACTOR (sys.indexes.fill_factor, 0 = default).
  fill_factor : Int
  /// IGNORE_DUP_KEY = ON: duplicate INSERT rows are skipped (3604).
  ignore_dup_key : Bool
  /// Constraint (PK/UNIQUE) rather than CREATE INDEX.
  is_constraint : Bool
  /// ALTER INDEX ... DISABLE: the index holds no rows and enforces nothing
  /// until REBUILD.
  disabled : Bool
} derive(Debug)

///|
/// Comparison of a filtered index conjunct.
pub(all) enum FilterOp {
  FEq
  FNe
  FLt
  FLe
  FGt
  FGe
} derive(Debug, Eq)

///|
/// One conjunct of a filtered index predicate over a column ordinal; the
/// constant is already converted to the column type.
pub(all) enum FilterTerm {
  FIsNull(Int)
  FCompare(Int, FilterOp, @types.Value)
} derive(Debug)

///|
/// Is `row` in the (filtered) index? NULL never satisfies a comparison.
pub fn Index::covers(self : Index, row : Array[@types.Value]) -> Bool {
  for c in self.not_null_filter {
    if c < row.length() && row[c] is Null {
      return false
    }
  }
  for term in self.filter_terms {
    match term {
      FIsNull(c) => if c < row.length() && !(row[c] is Null) { return false }
      FCompare(c, op, v) => {
        if c >= row.length() || row[c] is Null || v is Null {
          return false
        }
        let r = @types.compare(row[c], v) catch { _ => return false }
        guard r is Some(k) else { return false }
        let ok = match op {
          FEq => k == 0
          FNe => k != 0
          FLt => k < 0
          FLe => k <= 0
          FGt => k > 0
          FGe => k >= 0
        }
        if !ok {
          return false
        }
      }
    }
  }
  true
}

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
  /// SN: CREATE SYNONYM; `definition` holds the quoted base object name
  /// (`[dbo].[t]`, sys.synonyms.base_object_name).
  Synonym
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
  /// SET ANSI_NULLS at CREATE TABLE (sys.tables.uses_ansi_nulls).
  ansi_nulls : Bool
  /// The table has had a LOB column (max types, xml, text, ntext, image):
  /// sys.tables.lob_data_space_id stays 1 after it is dropped or narrowed,
  /// also through TRUNCATE and REBUILD (captured: tail5/b2-lob-space).
  /// Maintained by the Db writers (`Db::create_table`, `alter_table`,
  /// `replace_table`).
  lob_used : Bool
} derive(Debug)

///|
/// Whether the table has a LOB column now.
pub fn Table::has_lob(self : Table) -> Bool {
  self.columns
  .iter()
  .any(c => {
    c.ty
    is (VarChar(None, _)
    | NVarChar(None, _)
    | VarBinary(None)
    | Xml
    | Json
    | Text(_)
    | NText(_)
    | Image)
  })
}

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
  /// SET ANSI_NULLS when the module was created or altered: its statements
  /// run with it (sys.sql_modules.uses_ansi_nulls).
  ansi_nulls : Bool
  /// SET QUOTED_IDENTIFIER when the module was created or altered
  /// (sys.sql_modules.uses_quoted_identifier).
  quoted_identifier : Bool
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
    Synonym => ("SN", "SYNONYM")
  }
}

///|
/// A user-defined data type (CREATE TYPE): an alias of a system type or a
/// table type. Types live in their own namespace (sys.types), not in
/// sys.objects.
pub(all) struct UserType {
  /// sys.types.user_type_id (257, 258, ... per database).
  id : Int
  schema : String
  name : String
  /// Alias types: the base type and the type text as written (`nvarchar(256)`).
  base : @types.SqlType?
  /// Alias types: NOT NULL unless declared NULL (sys.types.is_nullable).
  nullable : Bool
  /// Table types: the type table (its id is type_table_object_id).
  table : Table?
  created : Int64
} derive(Debug)

///|
pub(all) struct JsonIndex {
  internal_id : Int
  created : Int64
  modified : Int64
  disabled_rows : Int64?
  paths : Array[String]
  prefixes : Array[String]
  array_search : Bool
  padded : Bool
  row_locks : Bool
  page_locks : Bool
  compression : Int
} derive(Debug)

///|
pub(all) struct VectorIndex {
  metric : VectorMetric
  start : Int
  parameters : String
} derive(Debug)
