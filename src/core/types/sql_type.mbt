// SQL types as the binder sees them: exact declared parameters, so result
// metadata (COLMETADATA) can be computed without looking at values.

///|
/// A declared SQL Server type. Lengths are in the type's own units
/// (characters for nchar/nvarchar, bytes for the rest); `None` means `max`.
/// `Decimal` and `Numeric` behave identically but are reported differently
/// on the wire (DECIMALN vs NUMERICN), so both are kept.
pub(all) enum SqlType {
  Bit
  TinyInt
  SmallInt
  Int
  BigInt
  /// decimal(precision 1..38, scale 0..precision)
  Decimal(Int, Int)
  /// numeric(precision, scale)
  Numeric(Int, Int)
  Money
  SmallMoney
  /// float(53) / double precision
  Float
  /// real / float(24)
  Real
  /// char(n), n bytes (1..8000), code page from the collation
  Char(Int, Collation)
  /// varchar(n | max)
  VarChar(Int?, Collation)
  /// nchar(n), n UTF-16 code units (1..4000)
  NChar(Int, Collation)
  /// nvarchar(n | max)
  NVarChar(Int?, Collation)
  /// binary(n)
  Binary(Int)
  /// varbinary(n | max)
  VarBinary(Int?)
  Date
  /// time(scale 0..7)
  Time(Int)
  /// datetime2(scale 0..7)
  DateTime2(Int)
  /// datetimeoffset(scale 0..7)
  DateTimeOffset(Int)
  /// legacy datetime (1/300 s)
  DateTime
  /// legacy smalldatetime (1 minute)
  SmallDateTime
  UniqueIdentifier
  /// rowversion / timestamp (binary(8) assigned by the engine)
  RowVersion
  /// sql_variant: values carry their base type (`Value::Variant`)
  Variant
  /// untyped xml (values are `Value::Xml`)
  Xml
  /// deprecated LOB types (lob.mbt): text and ntext keep `Value::String`,
  /// image `Value::Binary`
  Text(Collation)
  NText(Collation)
  Image
} derive(Debug, Eq)

///|
/// Coarse type family, used by conversion and comparison dispatch.
pub(all) enum TypeFamily {
  FBit
  FInteger
  FDecimal
  FMoney
  FFloat
  FString
  FBinary
  FDate
  FTime
  FDateTime
  FGuid
  FVariant
  FXml
} derive(Debug, Eq)

///|
pub fn SqlType::family(self : SqlType) -> TypeFamily {
  match self {
    Bit => FBit
    TinyInt | SmallInt | Int | BigInt => FInteger
    Decimal(_, _) | Numeric(_, _) => FDecimal
    Money | SmallMoney => FMoney
    Float | Real => FFloat
    Char(_, _)
    | VarChar(_, _)
    | NChar(_, _)
    | NVarChar(_, _)
    | Text(_)
    | NText(_) => FString
    Binary(_) | VarBinary(_) | RowVersion | Image => FBinary
    Date => FDate
    Time(_) => FTime
    DateTime2(_) | DateTimeOffset(_) | DateTime | SmallDateTime => FDateTime
    UniqueIdentifier => FGuid
    Variant => FVariant
    Xml => FXml
  }
}

///|
/// The base type name as SQL Server prints it in messages
/// (`int`, `numeric`, `nvarchar`, ...). Decimal prints as `numeric`, as in
/// "Arithmetic overflow error converting expression to data type numeric."
/// (captured even for DECIMAL operands, msduck reference/decimal-division.json).
pub fn SqlType::message_name(self : SqlType) -> String {
  match self {
    Decimal(_, _) => "numeric"
    _ => self.base_name()
  }
}

///|
/// Type name as used by type-clash and disallowed-conversion messages:
/// like `message_name` but max types print as `varchar(max)` (captured:
/// "Explicit conversion from data type image to varchar(max) is not
/// allowed.", msduck reference). Conversion-failure messages (245, 8114)
/// use the bare name even for max sources (reference/unicode-integer.json).
pub fn SqlType::clash_name(self : SqlType) -> String {
  match self {
    VarChar(None, _) | NVarChar(None, _) | VarBinary(None) =>
      self.base_name() + "(max)"
    // captured: "Explicit conversion from data type decimal to text is not
    // allowed." (529 keeps decimal, unlike the overflow messages)
    _ => self.base_name()
  }
}

///|
/// The base type name (`decimal`, `varchar`, `datetime2`, ...).
pub fn SqlType::base_name(self : SqlType) -> String {
  match self {
    Bit => "bit"
    TinyInt => "tinyint"
    SmallInt => "smallint"
    Int => "int"
    BigInt => "bigint"
    Decimal(_, _) => "decimal"
    Numeric(_, _) => "numeric"
    Money => "money"
    SmallMoney => "smallmoney"
    Float => "float"
    Real => "real"
    Char(_, _) => "char"
    VarChar(_, _) => "varchar"
    NChar(_, _) => "nchar"
    NVarChar(_, _) => "nvarchar"
    Binary(_) => "binary"
    VarBinary(_) => "varbinary"
    Date => "date"
    Time(_) => "time"
    DateTime2(_) => "datetime2"
    DateTimeOffset(_) => "datetimeoffset"
    DateTime => "datetime"
    SmallDateTime => "smalldatetime"
    UniqueIdentifier => "uniqueidentifier"
    RowVersion => "timestamp"
    Variant => "sql_variant"
    Xml => "xml"
    Text(_) => "text"
    NText(_) => "ntext"
    Image => "image"
  }
}

///|
/// The full declaration, e.g. `decimal(10,2)`, `nvarchar(max)`, `time(7)`.
pub fn SqlType::to_sql(self : SqlType) -> String {
  fn len(n : Int?) -> String {
    match n {
      Some(n) => n.to_string()
      None => "max"
    }
  }

  match self {
    Decimal(p, s) | Numeric(p, s) => "\{self.base_name()}(\{p},\{s})"
    Char(n, _) | NChar(n, _) | Binary(n) => "\{self.base_name()}(\{n})"
    VarChar(n, _) | NVarChar(n, _) | VarBinary(n) =>
      "\{self.base_name()}(\{len(n)})"
    Time(s) | DateTime2(s) | DateTimeOffset(s) => "\{self.base_name()}(\{s})"
    _ => self.base_name()
  }
}

///|
pub impl Show for SqlType with fn output(self, logger) {
  logger.write_string(self.to_sql())
}

///|
/// Character types: is the data Unicode (nchar/nvarchar)?
pub fn SqlType::is_unicode(self : SqlType) -> Bool {
  self is (NChar(_, _) | NVarChar(_, _) | NText(_))
}

///|
/// Collation of a character type.
pub fn SqlType::collation(self : SqlType) -> Collation? {
  match self {
    Char(_, c) | VarChar(_, c) | NChar(_, c) | NVarChar(_, c) => Some(c)
    Text(c) | NText(c) => Some(c)
    _ => None
  }
}

///|
/// Precision and scale of exact numerics, as SQL Server reports them
/// (and as used when an integer/money operand meets a decimal).
pub fn SqlType::precision_scale(self : SqlType) -> (Int, Int)? {
  match self {
    Bit => Some((1, 0))
    TinyInt => Some((3, 0))
    SmallInt => Some((5, 0))
    Int => Some((10, 0))
    BigInt => Some((19, 0))
    Decimal(p, s) | Numeric(p, s) => Some((p, s))
    SmallMoney => Some((10, 4))
    Money => Some((19, 4))
    _ => None
  }
}

///|
/// Are the declared parameters in range (precision 1..38, scale 0..p,
/// lengths 1..8000 bytes / 1..4000 characters, temporal scale 0..7)? The
/// binder raises the parse-time errors (1001/1002/131/2717) itself, from
/// captured message texts.
pub fn SqlType::is_valid(self : SqlType) -> Bool {
  match self {
    Decimal(p, s) | Numeric(p, s) => p >= 1 && p <= 38 && s >= 0 && s <= p
    Char(n, _) | Binary(n) | VarChar(Some(n), _) | VarBinary(Some(n)) =>
      n >= 1 && n <= 8000
    NChar(n, _) | NVarChar(Some(n), _) => n >= 1 && n <= 4000
    Time(s) | DateTime2(s) | DateTimeOffset(s) => s >= 0 && s <= 7
    _ => true
  }
}

///|
/// The same character type with another collation (other types unchanged).
pub fn SqlType::with_collation(self : SqlType, c : Collation) -> SqlType {
  match self {
    Char(n, _) => Char(n, c)
    VarChar(n, _) => VarChar(n, c)
    NChar(n, _) => NChar(n, c)
    NVarChar(n, _) => NVarChar(n, c)
    Text(_) => Text(c)
    NText(_) => NText(c)
    t => t
  }
}
