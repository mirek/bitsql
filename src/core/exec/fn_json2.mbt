// JSON_OBJECT, JSON_ARRAY and JSON_MODIFY (binder: bind/fn_json2.mbt;
// captures: harness/corpus/json2/*.sql).

///|
/// Text view for JSON functions; the native value retains storage provenance.
fn json_text_arg(value : @types.Value) -> @types.Value {
  match value {
    NativeJson(data) => String(data.navigation_text())
    other => other
  }
}

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
/// A float value of a json-typed result is stored as decimal(38,10)
/// (captured json4/returning: 1e29 is 8115, state 19 in the constructors,
/// 18 in JSON_MODIFY; the JSON aggregates format the float as text and
/// fail with 1007 instead).
fn json_float_check(
  v : @types.Value,
  state : Int,
) -> Unit raise @types.SqlError {
  if v is Float(d) && @types.json_type_decimal(d) is None {
    raise @types.sql_error(
      8115,
      "Arithmetic overflow error converting float to data type numeric.",
      state~,
    )
  }
}

///|
/// JSON errors of a json-type document use other states (captured
/// json4/type-functions): JSON_MODIFY 13608 state 5, 13621 state 2; a
/// strict range past the end is 13608 state 5 (not 13659).
fn json_type_error(e : @types.SqlError) -> @types.SqlError {
  match (e.number(), e.state()) {
    (22020, _) =>
      @types.sql_error(22020, e.message(), state=e.state(), severity=17)
    (13608, 2) | (13659, _) =>
      @types.sql_error(13608, @json.MISSING_MESSAGE, state=5)
    (13621, 1) => @types.sql_error(13621, e.message(), state=2)
    _ => e
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
      let flags = match json_text_arg(v[0]) {
        String(f) => f
        _ => "N"
      }
      let absent = flags.code_unit_at(0) is ('A' | 'a')
      let json_result = flags.code_unit_at(0) is ('a' | 'n')
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
        if json_result {
          json_float_check(value, 19)
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
      if json_result {
        Some(NativeJson(@types.JsonData::parse(buf.to_string())))
      } else {
        Some(String(buf.to_string()))
      }
    }
    "ISJSON" =>
      match json_text_arg(v[0]) {
        Null => Some(Null)
        String(doc) => {
          let ty : @json.IsJsonType = match v[1] {
            String("VALUE") => Value
            String("ARRAY") => Array
            String("OBJECT") => Object
            _ => Scalar
          }
          Some(Int(json(() => @json.isjson(doc, ty~))))
        }
        _ => raise @types.not_supported("ISJSON on non-character input")
      }
    "JSON_CONTAINS" => Some(json_contains(v, args))
    "JSON_PATH_EXISTS" =>
      match (json_text_arg(v[0]), v[1]) {
        (_, Null) =>
          raise @types.sql_error(
            8116,
            "Argument data type NULL is invalid for argument 2 of JSON_PATH_EXISTS function.",
            state=8,
          )
        (Null, _) => Some(Null)
        (String(doc), String(path)) =>
          Some(
            Int(
              json(() => {
                @json.json_path_exists(doc, path, native=args[0].ty is Json)
              }),
            ),
          )
        _ =>
          raise @types.not_supported("JSON_PATH_EXISTS on non-character input")
      }
    "JSON_MODIFY" | "JSON_MUTATE" => {
      if name == "JSON_MUTATE" {
        if v[0] is Null {
          let target = match v[4] {
            String(s) => s
            _ => ""
          }
          raise @types.sql_error(
            5302,
            "Mutator 'modify()' on '\{target}' cannot be called on a null value.",
          )
        }
        if v[1] is Null {
          return Some(v[0])
        }
      }
      match (json_text_arg(v[0]), v[1]) {
        (Null, _) => Some(Null)
        (_, Null) =>
          raise @types.sql_error(
            8116,
            "Argument data type NULL is invalid for argument 2 of JSON_MODIFY function.",
            state=8,
          )
        (String(doc), String(path)) => {
          let doc = match v[0] {
            NativeJson(data) => data.mutation_text()
            _ => doc
          }
          let raw = v[3] is String("j")
          let json_doc = args[0].ty is Json
          if json_doc {
            json_float_check(v[2], 18)
          }
          let text = match v[2] {
            Null => None
            String(s) if raw => Some(s)
            other => Some(json_modify_value(other, args[2].ty))
          }
          let path = if json_doc {
            let empty_storage = match v[0] {
              NativeJson(data) =>
                args[0].kind is Var(_) && data.storage_bytes() == 18
              _ => false
            }
            let mapped = json(() => {
              @json.native_modify_path(
                doc,
                path,
                name == "JSON_MUTATE",
                empty_storage,
              )
            }) catch {
              e => raise json_type_error(e)
            }
            match mapped {
              Some(path) => path
              None => return Some(v[0])
            }
          } else {
            path
          }
          let out = json(() => @json.json_modify(doc, path, text)) catch {
            e => raise if json_doc { json_type_error(e) } else { e }
          }
          if json_doc {
            guard v[0] is NativeJson(data) else {
              raise @types.emulator_error(
                @types.EMU_INTERNAL,
                "native JSON mutation input",
              )
            }
            Some(NativeJson(data.modified(out, path)))
          } else {
            Some(String(out))
          }
        }
        _ => raise @types.not_supported("JSON_MODIFY on non-character input")
      }
    }
    _ => None
  }
}
