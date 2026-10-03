// JSON_OBJECT, JSON_ARRAY and JSON_MODIFY (binder: bind/fn_json2.mbt;
// captures: harness/corpus/json2/*.sql).

///|
/// A value as JSON_OBJECT / JSON_ARRAY write it: FOR JSON's formatting,
/// except that date/time values drop an all-zero fraction (captured:
/// time '03:04:05', datetime2(0) and smalldatetime without fraction, but
/// time(4) '03:04:05.1200' and datetimeoffset(2) '...05.50-07:30').
/// The same holds for datetime ('2024-01-02T03:04:05').
fn json_ctor_value(
  v : @types.Value,
  ty : @types.SqlType,
) -> String raise @types.SqlError {
  let s = json_scalar(v, ty)
  match v {
    Time(_)
    | DateTime2(_)
    | DateTimeOffset(_, _)
    | DateTime(_, _)
    | SmallDateTime(_, _) => {
      // s is quoted: "...T03:04:05.000[+hh:mm]"
      let n = s.length()
      let mut dot = -1
      for i in 0..<n {
        if s.code_unit_at(i) == '.' {
          dot = i
          break
        }
      }
      if dot < 0 {
        return s
      }
      let mut j = dot + 1
      while j < n && s.code_unit_at(j) == '0' {
        j += 1
      }
      if j < n && s.code_unit_at(j) >= '1' && s.code_unit_at(j) <= '9' {
        s
      } else {
        s.unsafe_substring(start=0, end=dot) +
        s.unsafe_substring(start=j, end=n)
      }
    }
    _ => s
  }
}

///|
/// The new value's JSON text for JSON_MODIFY: strings escaped, numbers as
/// written, float and real both with 16 significant digits (captured:
/// json-modify-values), bit true/false.
fn json_modify_value(
  v : @types.Value,
  ty : @types.SqlType,
) -> String raise @types.SqlError {
  match v {
    Float(_) => json_scalar(v, Float)
    _ => json_scalar(v, ty)
  }
}

///|
fn call_json2(
  name : String,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
) -> @types.Value? raise @types.SqlError {
  match name {
    "JSON_OBJECT" | "JSON_ARRAY" => {
      let flags = match v[0] {
        String(f) => f
        _ => "N"
      }
      let absent = flags.code_unit_at(0) == 'A'
      let object = name == "JSON_OBJECT"
      let buf = StringBuilder()
      buf.write_char(if object { '{' } else { '[' })
      let mut first = true
      let step = if object { 2 } else { 1 }
      let mut i = 1
      let mut k = 1
      while i < v.length() {
        let vi = if object { i + 1 } else { i }
        let value = v[vi]
        let raw = flags.code_unit_at(k) == 'j'
        k += 1
        if object && v[i] is Null {
          raise @types.sql_error(
            13638, "User error : Name parameter value in 'json_object' cannot be null",
          )
        }
        if !(value is Null && absent) {
          if !first {
            buf.write_char(',')
          }
          first = false
          if object {
            let key = match v[i] {
              String(s) => s
              other => @types.render(other, args[i].ty, None)
            }
            buf.write_string(@json.quote(key))
            buf.write_char(':')
          }
          match value {
            Null => buf.write_string("null")
            String(s) if raw => buf.write_string(s)
            _ => buf.write_string(json_ctor_value(value, args[vi].ty))
          }
        }
        i += step
      }
      buf.write_char(if object { '}' } else { ']' })
      Some(String(buf.to_string()))
    }
    "JSON_MODIFY" =>
      match (v[0], v[1]) {
        (Null, _) => Some(Null)
        (_, Null) =>
          raise @types.sql_error(
            8116,
            "Argument data type NULL is invalid for argument 2 of JSON_MODIFY function.",
            state=8,
          )
        (String(doc), String(path)) => {
          let raw = v[3] is String("j")
          let text = match v[2] {
            Null => None
            String(s) if raw => Some(s)
            other => Some(json_modify_value(other, args[2].ty))
          }
          Some(String(json(() => @json.json_modify(doc, path, text))))
        }
        _ => raise @types.not_supported("JSON_MODIFY on non-character input")
      }
    _ => None
  }
}
