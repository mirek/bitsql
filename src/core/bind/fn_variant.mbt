// sql_variant in the binder: which operators and built-ins accept a
// sql_variant operand, the errors SQL Server raises for the others, and the
// functions returning sql_variant (SQL_VARIANT_PROPERTY, SERVERPROPERTY,
// DATABASEPROPERTYEX, CONNECTIONPROPERTY, SESSIONPROPERTY).
//
// The per-function table comes from one oracle probe per function and
// argument position (SQL Server 17.0.5005; corpus variant/functions.sql and
// docs/reference/sql-variant.md). A sql_variant never converts implicitly:
// some functions report 257 (conversion to their parameter type), others
// 8116. Built-ins not in the table raise an emulator error rather than
// silently converting.

///|
/// What a built-in does with a sql_variant argument.
priv enum VariantArg {
  /// The function takes sql_variant (ISNULL, COALESCE, DATALENGTH, ...).
  Accept
  /// 8116 "Argument data type sql_variant is invalid for argument N of F
  /// function."
  Invalid(String)
  /// 257 "Implicit conversion from data type sql_variant to T ..."
  Implicit(@types.SqlType)
  /// 257 to varchar, or nvarchar when another argument is Unicode
  /// (CONCAT, CONCAT_WS, CHARINDEX's second argument).
  ImplicitString
  /// Not captured: emulator error.
  Unknown
}

///|
fn v_varchar() -> @types.SqlType {
  VarChar(Some(1), @types.default_collation)
}

///|
fn v_nvarchar() -> @types.SqlType {
  NVarChar(Some(1), @types.default_collation)
}

///|
/// The rule for argument `i` (0-based) of built-in `name` (upper case);
/// None when `name` is not a built-in this table knows.
fn variant_arg_rule(name : String, i : Int) -> VariantArg? {
  let lower = name.to_lower()
  let inv = Invalid(lower)
  let int_ : VariantArg = Implicit(Int)
  let float_ : VariantArg = Implicit(Float)
  let datetime_ : VariantArg = Implicit(DateTime)
  let varchar_ : VariantArg = Implicit(v_varchar())
  let nvarchar_ : VariantArg = Implicit(v_nvarchar())
  let r : VariantArg = match name {
    // accepted
    "DATALENGTH"
    | "COALESCE"
    | "NULLIF"
    | "GREATEST"
    | "LEAST"
    | "MIN"
    | "MAX"
    | "COUNT"
    | "COUNT_BIG" => Accept
    // ISNULL's second argument converts to the first's type: its binder
    // raises the 257
    "ISNULL" | "IIF" => Accept
    "CHOOSE" => if i == 0 { int_ } else { Accept }
    "SQL_VARIANT_PROPERTY" => if i == 0 { Accept } else { varchar_ }
    // 8116 on every argument
    "LEN"
    | "UPPER"
    | "LOWER"
    | "LTRIM"
    | "RTRIM"
    | "REVERSE"
    | "SUBSTRING"
    | "REPLACE"
    | "PATINDEX"
    | "ASCII"
    | "UNICODE"
    | "STUFF"
    | "SOUNDEX"
    | "DIFFERENCE"
    | "FORMAT"
    | "TRANSLATE"
    | "STRING_ESCAPE"
    | "ISDATE"
    | "ISNUMERIC"
    | "HASHBYTES"
    | "JSON_VALUE"
    | "JSON_QUERY"
    | "ISJSON"
    | "SESSION_CONTEXT"
    | "STRING_AGG" => inv
    "TRIM" | "TRIM LEADING" | "TRIM TRAILING" => Invalid("Trim")
    "COMPRESS" => Invalid("Compress")
    "DECOMPRESS" => Invalid("Decompress")
    // mixed
    "LEFT" | "RIGHT" | "REPLICATE" => if i == 0 { inv } else { int_ }
    "CHARINDEX" => if i == 1 { ImplicitString } else { inv }
    "STR" => if i == 0 { float_ } else { inv }
    "ROUND" => if i == 0 { float_ } else { inv }
    "EOMONTH" => if i == 0 { inv } else { int_ }
    "PARSENAME" => if i == 0 { inv } else { int_ }
    "DATEADD" => if i == 1 { inv } else { datetime_ }
    "DATETRUNC" => inv
    "COLUMNPROPERTY" | "INDEXPROPERTY" =>
      match i {
        0 => inv
        1 => nvarchar_
        _ => varchar_
      }
    "OBJECTPROPERTY" => if i == 0 { int_ } else { varchar_ }
    "SWITCHOFFSET" =>
      if i == 0 {
        Implicit(DateTimeOffset(7))
      } else {
        Implicit(SmallInt)
      }
    "TODATETIMEOFFSET" =>
      if i == 0 {
        Implicit(DateTime2(7))
      } else {
        Implicit(SmallInt)
      }
    // 257 to the parameter type
    "CONCAT" | "CONCAT_WS" => ImplicitString
    "SPACE"
    | "NCHAR"
    | "CHAR"
    | "RAND"
    | "DATEFROMPARTS"
    | "TIMEFROMPARTS"
    | "DATETIME2FROMPARTS"
    | "DATETIMEFROMPARTS"
    | "SMALLDATETIMEFROMPARTS"
    | "DATETIMEOFFSETFROMPARTS"
    | "OBJECT_NAME"
    | "OBJECT_SCHEMA_NAME"
    | "OBJECT_DEFINITION"
    | "DB_NAME"
    | "SCHEMA_NAME"
    | "TYPE_NAME"
    | "COL_NAME"
    | "USER_NAME" => int_
    "ABS"
    | "CEILING"
    | "FLOOR"
    | "SIGN"
    | "POWER"
    | "SQRT"
    | "SQUARE"
    | "EXP"
    | "LOG"
    | "LOG10"
    | "SIN"
    | "COS"
    | "TAN"
    | "ASIN"
    | "ACOS"
    | "ATAN"
    | "ATN2"
    | "COT"
    | "RADIANS"
    | "DEGREES" => float_
    "DATEPART"
    | "DATENAME"
    | "YEAR"
    | "MONTH"
    | "DAY"
    | "DATEDIFF"
    | "DATEDIFF_BIG" => datetime_
    "QUOTENAME"
    | "OBJECT_ID"
    | "DB_ID"
    | "SCHEMA_ID"
    | "TYPE_ID"
    | "COL_LENGTH"
    | "IDENT_CURRENT"
    | "IDENT_SEED"
    | "IDENT_INCR"
    | "HAS_PERMS_BY_NAME"
    | "CURSOR_STATUS"
    | "SUSER_ID"
    | "USER_ID"
    | "IS_MEMBER"
    | "IS_SRVROLEMEMBER" => nvarchar_
    "DATABASEPROPERTYEX" => if i == 0 { nvarchar_ } else { varchar_ }
    "SERVERPROPERTY" | "CONNECTIONPROPERTY" | "SESSIONPROPERTY" => varchar_
    "SUSER_SNAME" => Implicit(VarBinary(Some(1)))
    // other built-ins bitsql binds (not captured with sql_variant)
    "CHECKSUM"
    | "BINARY_CHECKSUM"
    | "GETDATE"
    | "SYSDATETIME"
    | "NEWID"
    | "ERROR_NUMBER"
    | "ERROR_MESSAGE"
    | "XACT_STATE"
    | "SCOPE_IDENTITY"
    | "OPENJSON"
    | "STRING_SPLIT"
    | "TRIGGER_NESTLEVEL"
    | "FORMATMESSAGE"
    | "PI" => Unknown
    _ => return None
  }
  Some(r)
}

///|
/// Can this argument expression have type sql_variant? A cheap syntactic
/// filter so the guard only binds arguments twice when they might.
fn may_be_variant(e : @ast.Expr) -> Bool {
  match e.kind {
    Var(_) | Column(_) | Subquery(_) | Case(..) => true
    Cast(_, tn, ..) | Convert(tn, _, ..) => tn.name.to_lower() == "sql_variant"
    Paren(x) => may_be_variant(x)
    Call(c) =>
      c.name.parts.length() > 1 ||
      (match c.name.base().to_upper() {
        "SQL_VARIANT_PROPERTY"
        | "SERVERPROPERTY"
        | "DATABASEPROPERTYEX"
        | "CONNECTIONPROPERTY"
        | "SESSIONPROPERTY"
        | "SESSION_CONTEXT"
        | "ISNULL"
        | "COALESCE"
        | "NULLIF"
        | "IIF"
        | "CHOOSE"
        | "GREATEST"
        | "LEAST"
        | "MIN"
        | "MAX"
        | "FIRST_VALUE"
        | "LAST_VALUE"
        | "LAG"
        | "LEAD" => true
        _ => false
      })
    _ => false
  }
}

///|
/// Raises SQL Server's error when a built-in gets a sql_variant argument it
/// does not take (see the table above). Runs before the function's own
/// binder, so a silent implicit conversion never happens.
fn variant_guard(
  env : Env,
  name : String,
  args : Array[@ast.Expr],
) -> Unit raise @types.SqlError {
  for i, a in args {
    // datepart keywords are not expressions
    if i == 0 &&
      name
      is ("DATEADD"
      | "DATEDIFF"
      | "DATEDIFF_BIG"
      | "DATEPART"
      | "DATENAME"
      | "DATETRUNC") {
      continue
    }
    if !may_be_variant(a) {
      continue
    }
    let ty = try bind_expr(env, a) catch {
      _ => continue
    } noraise {
      b => b.ty
    }
    if !(ty is Variant) {
      continue
    }
    guard variant_arg_rule(name, i) is Some(rule) else { return }
    match rule {
      Accept => ()
      Invalid(fname) => raise bad_arg_type(ty, i + 1, fname)
      Implicit(t) => raise @types.implicit_conversion_error(Variant, t)
      ImplicitString => {
        let unicode = args
          .iter()
          .any(x => {
            !physical_equal(x, a) &&
            (try bind_expr(env, x) catch {
              _ => false
            } noraise {
              b => b.ty.is_unicode()
            })
          })
        raise @types.implicit_conversion_error(
          Variant,
          if unicode {
            v_nvarchar()
          } else {
            v_varchar()
          },
        )
      }
      Unknown => raise @types.not_supported("a sql_variant argument to \{name}")
    }
  }
}

///|
/// Operand checks for operators (captured, variant/operators.sql):
/// arithmetic with a numeric operand is 257 (sql_variant to that type),
/// with anything else 402; modulo is always 402; bitwise operators are 402,
/// or 8117 when both operands are sql_variant.
fn variant_operator_check(
  op : @ast.BinOp,
  a : @ir.Expr,
  b : @ir.Expr,
) -> Unit raise @types.SqlError {
  if !(a.ty is Variant) && !(b.ty is Variant) {
    return
  }
  let label = (e : @ir.Expr) => {
    if is_null_lit(e) {
      "NULL"
    } else {
      e.ty.clash_name()
    }
  }
  let sym = match op {
    BitAnd => Some("'&'")
    BitOr => Some("'|'")
    BitXor => Some("'^'")
    _ => None
  }
  match sym {
    Some(s) =>
      if a.ty is Variant && b.ty is Variant {
        raise err(
          8117,
          "Operand data type sql_variant is invalid for \{s} operator.",
        )
      } else {
        raise err(
          402,
          "The data types \{label(a)} and \{label(b)} are incompatible in the \{s} operator.",
        )
      }
    None => {
      let aop : @types.ArithOp = match op {
        Add => Add
        Sub => Sub
        Mul => Mul
        Div => Div
        _ => Mod
      }
      let name = (e : @ir.Expr) => {
        if is_null_lit(e) {
          Some("NULL")
        } else {
          None
        }
      }
      raise @types.variant_arith_error(
        aop,
        a.ty,
        b.ty,
        a_name?=name(a),
        b_name?=name(b),
      )
    }
  }
}

///|
/// Unary minus and `~` on a sql_variant: 8117 (captured).
fn variant_unary_check(
  op : @ast.UnaryOp,
  a : @ir.Expr,
) -> Unit raise @types.SqlError {
  if !(a.ty is Variant) {
    return
  }
  match op {
    Neg =>
      raise err(
        8117, "Operand data type sql_variant is invalid for minus operator.",
      )
    BitNot =>
      raise err(
        8117, "Operand data type sql_variant is invalid for '~' operator.",
      )
    Plus => raise @types.not_supported("unary plus on sql_variant")
  }
}

///|
/// LIKE operands (and ESCAPE): 8116 "... of like function." (captured).
fn variant_like_check(
  a : @ir.Expr,
  p : @ir.Expr,
  esc : @ir.Expr?,
) -> Unit raise @types.SqlError {
  let ops = [a, p]
  if esc is Some(e) {
    ops.push(e)
  }
  for i, e in ops {
    if e.ty is Variant {
      raise bad_arg_type(e.ty, i + 1, "like")
    }
  }
}

///|
/// Functions returning sql_variant. None = not one of them.
fn bind_variant_fn(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  let args = call.args
  let text_arg = (i : Int, t : @types.SqlType) => {
    let x = bind_expr(env, args[i])
    if is_null_lit(x) {
      x
    } else {
      coerce(x, t)
    }
  }
  let varchar : @types.SqlType = VarChar(Some(8000), env.collation)
  let r = match name {
    "SQL_VARIANT_PROPERTY" => {
      arity_n(name, args, 2)
      let v = coerce(bind_expr(env, args[0]), Variant)
      named(name, [v, text_arg(1, varchar)], Variant)
    }
    "SERVERPROPERTY" | "CONNECTIONPROPERTY" | "SESSIONPROPERTY" => {
      arity_n(name, args, 1)
      named(name, [text_arg(0, varchar)], Variant)
    }
    "DATABASEPROPERTYEX" => {
      arity_n(name, args, 2)
      named(
        name,
        [text_arg(0, NVarChar(Some(128), env.collation)), text_arg(1, varchar)],
        Variant,
      )
    }
    _ => return None
  }
  Some(r)
}

///|
/// CAST of a constant sql_variant whose base type cannot convert: SQL
/// Server folds the constant and reports 529 state 3 at compile time
/// (before COLMETADATA); for non-constant operands the same error comes at
/// run time (captured: variant/conversions.sql).
fn variant_constant_cast_check(
  a : @ir.Expr,
  t : @types.SqlType,
) -> Unit raise @types.SqlError {
  if !(a.ty is Variant) || t is Variant {
    return
  }
  if fold(a) is Some(Variant(_, base)) &&
    !@types.can_convert_explicitly(base, t) {
    raise err(
      529,
      "Explicit conversion from data type \{base.clash_name()} to \{t.clash_name()} is not allowed.",
      state=3,
    )
  }
}
