///|
/// Where a type name appears: omitted character lengths default to 1 in
/// declarations and to 30 in CAST/CONVERT (mssqlite-todo/character-cast-width).
pub(all) enum TypeContext {
  Declaration
  Conversion
} derive(Debug, Eq)

///|
fn num_arg(t : @ast.TypeName, i : Int) -> Int? raise @types.SqlError {
  match t.args.get(i) {
    Some(Num(s)) => {
      let mut v = 0
      for c in s {
        if c < '0' || c > '9' {
          raise @types.sql_error(
            102,
            "Incorrect syntax near '\{s}'.",
            severity=15,
          )
        }
        v = v * 10 + (c.to_int() - '0'.to_int())
      }
      Some(v)
    }
    _ => None
  }
}

///|
fn arg_is_max(t : @ast.TypeName, i : Int) -> Bool {
  t.args.get(i) is Some(Max)
}

///|
/// Resolves a syntactic type name to an `SqlType`.
pub fn resolve_type(
  t : @ast.TypeName,
  ctx : TypeContext,
  collation : @types.Collation,
) -> @types.SqlType raise @types.SqlError {
  let name = t.name.to_lower()
  let default_len = if ctx == Conversion { 30 } else { 1 }
  let len = num_arg(t, 0)
  let ty : @types.SqlType = match name {
    "bit" => Bit
    "tinyint" => TinyInt
    "smallint" => SmallInt
    "int" | "integer" => Int
    "bigint" => BigInt
    "decimal" | "dec" | "numeric" => {
      let p = len.unwrap_or(18)
      let s = num_arg(t, 1).unwrap_or(0)
      if name == "numeric" {
        Numeric(p, s)
      } else {
        Decimal(p, s)
      }
    }
    "money" => Money
    "smallmoney" => SmallMoney
    "float" =>
      match len {
        Some(n) if n <= 24 => Real
        _ => Float
      }
    "real" => Real
    // ISO synonym of float(53); Sequelize's DataTypes.DOUBLE (captured,
    // corpus orm/double-precision)
    "double precision" => Float
    "char" | "character" => Char(len.unwrap_or(default_len), collation)
    "varchar" =>
      VarChar(
        if arg_is_max(t, 0) {
          None
        } else {
          Some(len.unwrap_or(default_len))
        },
        collation,
      )
    "nchar" => NChar(len.unwrap_or(default_len), collation)
    "nvarchar" =>
      NVarChar(
        if arg_is_max(t, 0) {
          None
        } else {
          Some(len.unwrap_or(default_len))
        },
        collation,
      )
    "sysname" => NVarChar(Some(128), collation)
    "binary" => Binary(len.unwrap_or(default_len))
    "varbinary" =>
      VarBinary(
        if arg_is_max(t, 0) {
          None
        } else {
          Some(len.unwrap_or(default_len))
        },
      )
    "date" => Date
    "time" => Time(len.unwrap_or(7))
    "datetime2" => DateTime2(len.unwrap_or(7))
    "datetimeoffset" => DateTimeOffset(len.unwrap_or(7))
    "datetime" => DateTime
    "smalldatetime" => SmallDateTime
    "uniqueidentifier" => UniqueIdentifier
    "rowversion" | "timestamp" => RowVersion
    "sql_variant" => Variant
    "xml" => Xml
    "text" => Text(collation)
    "ntext" => NText(collation)
    "image" => Image
    // SQL Server 2025's json type (sent to clients as varchar(max) UTF-8);
    // captured json4: `json(100)` is 2716
    "json" if t.schema is None || t.schema.unwrap().name.to_lower() == "sys" => {
      if !t.args.is_empty() && ctx == Conversion {
        raise @types.sql_error(
          291,
          "CAST or CONVERT: invalid attributes specified for type '\{t.name}'",
        )
      }
      if !t.args.is_empty() {
        raise @types.sql_error(
          2716,
          "Column, parameter, or variable #1: Cannot specify a column width on data type \{t.name}.",
        )
      }
      Json
    }
    "vector" if t.schema is None || t.schema.unwrap().name.to_lower() == "sys" => {
      match t.args.get(1) {
        Some(Named(base)) if base.to_lower() == "float32" => ()
        Some(Named(base)) =>
          raise @types.sql_error(
            195,
            "'\{base.to_lower()}' is not a recognized vector base type.",
            severity=15,
          )
        Some(_) =>
          raise @types.sql_error(
            2715,
            "Column, parameter, or variable #1: Cannot find data type \{t.name}.",
            state=3,
          )
        None => ()
      }
      guard len is Some(n) else {
        raise @types.sql_error(
          2715,
          "Column, parameter, or variable #1: Cannot find data type \{t.name}.",
          state=3,
        )
      }
      if n < 1 {
        raise @types.sql_error(
          1001,
          "Line 1: Length or precision specification \{n} is invalid.",
          severity=15,
        )
      }
      if n > 1998 {
        raise @types.sql_error(
          2717,
          "The size (\{n}) given to the type 'vector' exceeds the maximum allowed (1998).",
          state=3,
          severity=15,
        )
      }
      Vector(n)
    }
    // CLR system types exist in SQL Server but are not emulated
    "hierarchyid" | "geometry" | "geography" if t.schema is None ||
      t.schema.unwrap().name.to_lower() == "sys" =>
      raise @types.not_supported("the \{t.name.to_lower()} data type")
    _ =>
      raise @types.sql_error(
        2715,
        "Column, parameter, or variable #1: Cannot find data type \{t.name}.",
        state=6,
      )
  }
  if !ty.is_valid() {
    raise @types.sql_error(
      2716,
      "Column, parameter, or variable #1: Cannot specify a column width on data type \{t.name}.",
    )
  }
  ty
}
