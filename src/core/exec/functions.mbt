///|
fn str_arg(v : @types.Value) -> String? {
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
fn int_arg(v : @types.Value) -> Int64? {
  v.as_int64()
}

///|
fn rtrim_spaces(s : String) -> String {
  let mut n = s.length()
  while n > 0 && s.code_unit_at(n - 1).to_int() == 0x20 {
    n -= 1
  }
  s.unsafe_substring(start=0, end=n)
}

///|
fn ltrim_chars(s : String, set : String) -> String {
  let mut i = 0
  while i < s.length() &&
        set.contains_char(s.code_unit_at(i).to_int().unsafe_to_char()) {
    i += 1
  }
  s.unsafe_substring(start=i, end=s.length())
}

///|
fn rtrim_chars(s : String, set : String) -> String {
  let mut n = s.length()
  while n > 0 &&
        set.contains_char(s.code_unit_at(n - 1).to_int().unsafe_to_char()) {
    n -= 1
  }
  s.unsafe_substring(start=0, end=n)
}

///|
fn ci_of(t : @types.SqlType) -> Bool {
  match t.collation() {
    Some(c) => !c.case_sensitive
    None => true
  }
}

///|
fn fold_str(s : String, ci : Bool) -> String {
  if ci {
    s.to_lower()
  } else {
    s
  }
}

///|
/// 1-based position of `needle` in `hay` at or after `start`, 0 if absent.
fn index_of(hay : String, needle : String, start : Int, ci : Bool) -> Int {
  if needle.length() == 0 {
    return 0
  }
  let h = fold_str(hay, ci)
  let n = fold_str(needle, ci)
  let from = @cmp.maximum(0, start - 1)
  let mut i = from
  while i + n.length() <= h.length() {
    if h.unsafe_substring(start=i, end=i + n.length()) == n {
      return i + 1
    }
    i += 1
  }
  0
}

///|
fn new_guid(rt : Runtime) -> Bytes {
  let a = rt.next_random()
  let b = rt.next_random()
  let bytes = Bytes::makei(16, i => {
    let w = if i < 8 { a } else { b }
    ((w >> (8 * (i % 8))) & 0xFFUL).to_byte()
  })
  // version 4 / RFC 4122 variant bits in SQL Server byte order
  let arr = bytes.to_array()
  arr[7] = ((arr[7].to_int() & 0x0F) | 0x40).to_byte()
  arr[8] = ((arr[8].to_int() & 0x3F) | 0x80).to_byte()
  Bytes::from_array(arr)
}

///|
fn call(
  ctx : Ctx,
  f : @ir.Fn,
  args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value raise @types.SqlError {
  let rt = ctx.rt
  let v = args.map(a => eval(ctx, a))
  let any_null = v.iter().any(x => x is Null)
  match f {
    Len =>
      match v[0] {
        Null => Null
        String(s) => int_result(e.ty, rtrim_spaces(s).length().to_int64())
        Binary(b) => int_result(e.ty, b.length().to_int64())
        other => {
          let s = @types.cast(
            other,
            args[0].ty,
            VarChar(Some(8000), @types.default_collation),
          )
          match s {
            String(x) => int_result(e.ty, rtrim_spaces(x).length().to_int64())
            _ => Null
          }
        }
      }
    DataLength =>
      match v[0] {
        Null => Null
        String(s) =>
          int_result(
            e.ty,
            (if args[0].ty.is_unicode() { s.length() * 2 } else { s.length() }).to_int64(),
          )
        Binary(b) => int_result(e.ty, b.length().to_int64())
        Bit(_) | TinyInt(_) => int_result(e.ty, 1)
        SmallInt(_) => int_result(e.ty, 2)
        Int(_) | Date(_) =>
          int_result(e.ty, if v[0] is Date(_) { 3 } else { 4 })
        BigInt(_) | Float(_) | Money(_) | DateTime(_, _) => int_result(e.ty, 8)
        Guid(_) => int_result(e.ty, 16)
        _ => raise @types.not_supported("DATALENGTH of this type")
      }
    Upper | Lower | Reverse =>
      match v[0] {
        String(s) =>
          String(
            match f {
              Upper => s.to_upper()
              Lower => s.to_lower()
              _ => s.rev()
            },
          )
        Null => Null
        other => other
      }
    LTrim | RTrim | Trim => {
      if any_null {
        return Null
      }
      guard str_arg(v[0]) is Some(s) else { return v[0] }
      let set = if v.length() > 1 { str_arg(v[1]).unwrap_or(" ") } else { " " }
      String(
        match f {
          LTrim => ltrim_chars(s, set)
          RTrim => rtrim_chars(s, set)
          _ => rtrim_chars(ltrim_chars(s, set), set)
        },
      )
    }
    Left | Right => {
      if any_null {
        return Null
      }
      guard str_arg(v[0]) is Some(s) else {
        raise @types.not_supported("LEFT/RIGHT on non-strings")
      }
      let n = int_arg(v[1]).unwrap_or(0L).to_int()
      if n < 0 {
        raise @types.sql_error(
          536,
          "Invalid length parameter passed to the \{if f == Left { "left" } else { "right" }} function.",
        )
      }
      let k = @cmp.minimum(n, s.length())
      String(
        if f == Left {
          s.unsafe_substring(start=0, end=k)
        } else {
          s.unsafe_substring(start=s.length() - k, end=s.length())
        },
      )
    }
    Substring => {
      if any_null {
        return Null
      }
      let start = int_arg(v[1]).unwrap_or(1L).to_int()
      let len = int_arg(v[2]).unwrap_or(0L).to_int()
      if len < 0 {
        raise @types.sql_error(
          537, "Invalid length parameter passed to the substring function.",
        )
      }
      match v[0] {
        String(s) => {
          let from = @cmp.maximum(start, 1)
          let to = @cmp.minimum(start + len, s.length() + 1)
          String(
            if to <= from {
              ""
            } else {
              s.unsafe_substring(start=from - 1, end=to - 1)
            },
          )
        }
        Binary(b) => {
          let from = @cmp.maximum(start, 1)
          let to = @cmp.minimum(start + len, b.length() + 1)
          Binary(if to <= from { b"" } else { b[from - 1:to - 1].to_owned() })
        }
        _ => raise @types.not_supported("SUBSTRING on this type")
      }
    }
    Replace => {
      if any_null {
        return Null
      }
      match (str_arg(v[0]), str_arg(v[1]), str_arg(v[2])) {
        (Some(s), Some(find), Some(rep)) => {
          if find.length() == 0 {
            return String(s)
          }
          let ci = ci_of(args[0].ty)
          let out = StringBuilder()
          let mut i = 0
          while i < s.length() {
            let pos = index_of(s, find, i + 1, ci)
            if pos == 0 {
              out.write_string(s.unsafe_substring(start=i, end=s.length()))
              break
            }
            out.write_string(s.unsafe_substring(start=i, end=pos - 1))
            out.write_string(rep)
            i = pos - 1 + find.length()
          }
          String(out.to_string())
        }
        _ => raise @types.not_supported("REPLACE on non-strings")
      }
    }
    Replicate => {
      if any_null {
        return Null
      }
      let n = int_arg(v[1]).unwrap_or(0L)
      if n < 0L {
        return Null
      }
      match v[0] {
        String(s) => {
          if s.length() == 0 || n == 0L {
            return String("")
          }
          // Non-max results are truncated to the type's length (8000 bytes;
          // captured: msduck replicate DATALENGTH 8000). Never build huge
          // strings: String::repeat aborts the process on overflow.
          let cap = match e.ty {
            VarChar(Some(k), _) | NVarChar(Some(k), _) => k
            _ => 64 * 1024 * 1024
          }
          let wanted = n * s.length().to_int64()
          if wanted > cap.to_int64() &&
            e.ty is (VarChar(None, _) | NVarChar(None, _)) {
            raise @types.not_supported("REPLICATE results over 64M characters")
          }
          let times = ((cap + s.length() - 1) / s.length()).to_int64()
          let k = (if n < times { n } else { times }).to_int()
          let r = s.repeat(k)
          String(
            if r.length() > cap {
              r.unsafe_substring(start=0, end=cap)
            } else {
              r
            },
          )
        }
        _ => raise @types.not_supported("REPLICATE on non-strings")
      }
    }
    CharIndex => {
      if v[0] is Null || v[1] is Null {
        return Null
      }
      let start = if v.length() > 2 {
        int_arg(v[2]).unwrap_or(1L).to_int()
      } else {
        1
      }
      match (str_arg(v[0]), str_arg(v[1])) {
        (Some(n), Some(h)) =>
          int_result(e.ty, index_of(h, n, start, ci_of(args[1].ty)).to_int64())
        _ => raise @types.not_supported("CHARINDEX on non-strings")
      }
    }
    Concat => {
      let out = StringBuilder()
      for i, x in v {
        match x {
          Null => ()
          String(s) => out.write_string(s)
          other =>
            match
              @types.cast(
                other,
                args[i].ty,
                NVarChar(None, @types.default_collation),
              ) {
              String(s) => out.write_string(s)
              _ => ()
            }
        }
      }
      String(out.to_string())
    }
    Space => {
      if any_null {
        return Null
      }
      let n = int_arg(v[0]).unwrap_or(0L)
      if n < 0L {
        Null
      } else {
        // SPACE returns varchar(8000) at most: never allocate more
        String(" ".repeat((if n > 8000L { 8000L } else { n }).to_int()))
      }
    }
    Nchar | Char => {
      if any_null {
        return Null
      }
      let n = int_arg(v[0]).unwrap_or(0L).to_int()
      let limit = if f == Char { 255 } else { 0xFFFF }
      if n < 0 || n > limit {
        Null
      } else if f == Char {
        String(@types.cp1252_decode(n).unsafe_to_char().to_string())
      } else {
        String(n.unsafe_to_char().to_string())
      }
    }
    Ascii | Unicode =>
      match v[0] {
        String(s) if s.length() > 0 => {
          let c = s.code_unit_at(0).to_int()
          if f == Ascii {
            Int(@types.cp1252_byte_of(c))
          } else {
            Int(c)
          }
        }
        _ => Null
      }
    Abs | Sign | Ceiling | Floor | Round | Power | Sqrt => math(f, v, args, e)
    IsNull => if v[0] is Null { v[1] } else { v[0] }
    NullIf | Iif => raise @types.not_supported("internal: rewritten function")
    ConcatWs | Str => raise @types.not_supported("CONCAT_WS / STR")
    XactState =>
      SmallInt(
        if rt.xact_state == 0 && rt.trancount == 0 && rt.stmt_reads {
          1
        } else {
          rt.xact_state
        },
      )
    ErrorNumber =>
      match rt.catch_error {
        Some(x) => Int(x.number)
        None => Null
      }
    ErrorMessage =>
      match rt.catch_error {
        Some(x) => String(x.message)
        None => Null
      }
    ErrorSeverity =>
      match rt.catch_error {
        Some(x) => Int(x.severity)
        None => Null
      }
    ErrorState =>
      match rt.catch_error {
        Some(x) => Int(x.state)
        None => Null
      }
    ErrorLine =>
      match rt.catch_error {
        Some(x) => Int(x.line)
        None => Null
      }
    ErrorProcedure =>
      match rt.catch_error {
        Some({ procedure: Some(p), .. }) => String(p)
        _ => Null
      }
    ScopeIdentity => rt.scope_identity
    NewId => Guid(new_guid(rt))
    GetDate | GetUtcDate => {
      // datetime: days since 1900 and 1/300 s units (UTC; no time zone)
      let days = (rt.now / @types.TICKS_PER_DAY).to_int() - @types.DAYS_TO_1900
      let ticks = rt.now % @types.TICKS_PER_DAY
      DateTime(days, @types.ticks_to_datetime_units(ticks).to_int())
    }
    SysDateTime | SysUtcDateTime => DateTime2(rt.now)
    SysDateTimeOffset => DateTimeOffset(rt.now, 0)
    DbName =>
      if v.length() == 0 {
        String(rt.database)
      } else {
        raise @types.not_supported("DB_NAME(id)")
      }
    SchemaName | ObjectId | ObjectName =>
      raise @types.not_supported("catalog functions")
    JsonValue =>
      match (v[0], v[1]) {
        // the NULL path is checked first (captured: msduck
        // unicode-json-storage#459)
        (_, Null) =>
          raise @types.sql_error(
            8116,
            "Argument data type NULL is invalid for argument 2 of JSON_VALUE function.",
            state=8,
          )
        (Null, _) => Null
        (String(doc), String(path)) =>
          match
            json(() => @json.json_value(doc, path, lob=json_lob(args[0].ty))) {
            Some(s) => String(s)
            None => Null
          }
        _ => raise @types.not_supported("JSON_VALUE on non-character input")
      }
    JsonQuery => {
      let path = if v.length() > 1 { v[1] } else { String("$") }
      match (v[0], path) {
        (_, Null) =>
          raise @types.sql_error(
            8116,
            "Argument data type NULL is invalid for argument 2 of JSON_QUERY function.",
            state=8,
          )
        (Null, _) => Null
        (String(doc), String(p)) =>
          match
            json(() => @json.json_query(doc, path=p, lob=json_lob(args[0].ty))) {
            Some(s) => String(s)
            None => Null
          }
        _ => raise @types.not_supported("JSON_QUERY on non-character input")
      }
    }
    Named(name) =>
      match (ctx.ext)(name, v) {
        Some(r) => r
        None => call_more(ctx, name, v, args, e)
      }
    IsJson =>
      match v[0] {
        Null => Null
        String(doc) => Int(json(() => Some(@json.isjson(doc))).unwrap_or(0))
        _ => raise @types.not_supported("ISJSON on non-character input")
      }
  }
}

///|
/// Whether a JSON function's document argument is a max type (SQL Server
/// reports other error states for those; see `@json.json_value`).
fn json_lob(t : @types.SqlType) -> Bool {
  t is (VarChar(None, _) | NVarChar(None, _))
}

///|
fn[T] json(f : () -> T raise @json.JsonError) -> T raise @types.SqlError {
  f() catch {
    @json.JsonError(n, st, m) => raise @types.sql_error(n, m, state=st)
  }
}

///|
fn int_result(ty : @types.SqlType, n : Int64) -> @types.Value {
  match ty {
    BigInt => BigInt(n)
    _ => Int(n.to_int())
  }
}

///|
fn math(
  f : @ir.Fn,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value raise @types.SqlError {
  if v.iter().any(x => x is Null) {
    return Null
  }
  // Work in the result type: convert the argument first.
  let x = @types.cast(v[0], args[0].ty, e.ty)
  match (f, x) {
    (Abs, Int(i)) =>
      if i == -2147483648 {
        raise @types.overflow_expression(Int)
      } else {
        Int(i.abs())
      }
    (Abs, BigInt(i)) =>
      if i == -9223372036854775807L - 1L {
        raise @types.overflow_expression(BigInt)
      } else {
        BigInt(i.abs())
      }
    (Abs, Float(d)) => Float(d.abs())
    (Abs, Decimal(d)) => Decimal(if d.sign() < 0 { d.neg() } else { d })
    (Sign, Int(i)) => Int(if i > 0 { 1 } else if i < 0 { -1 } else { 0 })
    (Sign, BigInt(i)) =>
      BigInt(if i > 0L { 1L } else if i < 0L { -1L } else { 0L })
    (Sign, Float(d)) =>
      Float(if d > 0.0 { 1.0 } else if d < 0.0 { -1.0 } else { 0.0 })
    (Sign, Decimal(d)) =>
      Decimal(@types.Decimal::from_int64(d.sign().to_int64(), scale=d.scale()))
    (Ceiling | Floor, Int(_) | BigInt(_)) => x
    (Ceiling, Float(d)) => Float(d.ceil())
    (Floor, Float(d)) => Float(d.floor())
    (Sqrt, _) =>
      match @types.cast(v[0], args[0].ty, Float) {
        Float(d) =>
          if d < 0.0 {
            raise @types.sql_error(
              3623, "An invalid floating point operation occurred.",
            )
          } else {
            Float(d.sqrt())
          }
        _ => Null
      }
    _ => raise @types.not_supported("\{@ir.debug_fn(f)} for \{e.ty}")
  }
}
