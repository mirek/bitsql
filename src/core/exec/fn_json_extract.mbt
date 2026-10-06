///|
fn json_value_returning(
  ctx : Ctx,
  values : Array[@types.Value],
  target : @types.SqlType,
) -> @types.Value raise @types.SqlError {
  if values[1] is Null {
    raise @types.sql_error(
      8116,
      "Argument data type NULL is invalid for argument 2 of JSON_VALUE function.",
      state=8,
    )
  }
  if values[0] is Null {
    return Null
  }
  guard values[0] is NativeJson(data) && values[1] is String(path) else {
    raise @types.not_supported("typed JSON_VALUE argument representation")
  }
  let p = json(() => @json.parse_path(path, native=true))
  let doc = data.scalar_text(path)
  guard json(() => @json.json_value_typed(doc, path)) is Some(row) &&
    row.value is Some(text) else {
    return Null
  }
  let (value, source) : (@types.Value, @types.SqlType) = match row.ty {
    3 if target.family() == FString =>
      (String(text), VarChar(None, @types.json_collation))
    3 => (Bit(text == "true"), Bit)
    2 => {
      guard @types.Decimal::parse(text[:]) is Some(d) else {
        raise @types.not_supported("noncanonical native JSON scalar number")
      }
      let coef = d.coef()
      if d.scale() == 0 &&
        coef.compare_int(-2147483648) >= 0 &&
        coef.compare_int(2147483647) <= 0 {
        (Int(coef.to_int()), Int)
      } else if d.scale() == 0 &&
        coef >= @bigint.BigInt::from_int64(-9223372036854775808L) &&
        coef <= @bigint.BigInt::from_int64(9223372036854775807L) {
        (BigInt(coef.to_int64()), BigInt)
      } else {
        (Decimal(d), Numeric(d.digits().max(d.scale()).max(1), d.scale()))
      }
    }
    _ => (String(text), VarChar(None, @types.json_collation))
  }
  let convert = () => {
    let unlimited : @types.SqlType = match target {
      VarChar(_, c) | Char(_, c) => VarChar(None, c)
      NVarChar(_, c) | NChar(_, c) => NVarChar(None, c)
      other => other
    }
    let result = @types.cast(value, source, unlimited, dates=ctx.rt.dates)
    if result is String(s) {
      let too_long = match target {
        VarChar(Some(n), c) | Char(n, c) =>
          @types.varchar_bytes(s, c).length() > n
        NVarChar(Some(n), _) | NChar(n, _) => s.length() > n
        _ => false
      }
      if too_long {
        raise @types.sql_error(
          8152,
          "String or binary data would be truncated.",
          state=34,
        )
      }
    }
    if unlimited == target {
      result
    } else {
      @types.cast(result, unlimited, target, dates=ctx.rt.dates)
    }
  }
  convert() catch {
    e if !p.strict && e.number() is (220 | 245 | 8114 | 8115 | 8152 | 241 | 242) =>
      Null
    e if e.number() == 529 && source is BigInt =>
      raise @types.sql_error(
        529,
        e.message().replace(old="data type bigint", new="data type int"),
        state=e.state(),
      )
    e => raise e
  }
}
