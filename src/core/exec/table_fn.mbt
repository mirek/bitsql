///|
/// Table-valued functions: OPENJSON and STRING_SPLIT.
fn run_table_fn(
  ctx : Ctx,
  f : @ir.TableFn,
  args : Array[@ir.Expr],
) -> Array[Row] raise @types.SqlError {
  let out = []
  stream_table_fn(ctx, f, args, r => out.push(r))
  out
}

///|
/// Emits rows one by one: OPENJSON WITH conversion errors surface after the
/// earlier rows (captured: query/table-functions step 3).
fn stream_table_fn(
  ctx : Ctx,
  f : @ir.TableFn,
  args : Array[@ir.Expr],
  emit : (Row) -> Unit raise @types.SqlError,
) -> Unit raise @types.SqlError {
  let open_input = (v : @types.Value) => {
    match v {
      Null => None
      NativeJson(data) => Some(data.navigation_text())
      other =>
        match
          @types.cast(
            other,
            args[0].ty,
            NVarChar(None, @types.default_collation),
          ) {
          String(s) => Some(s)
          _ => None
        }
    }
  }
  let text = (i : Int) => {
    match eval(ctx, args[i]) {
      Null => None
      v =>
        match
          @types.cast(v, args[i].ty, NVarChar(None, @types.default_collation)) {
          String(s) => Some(s)
          _ => None
        }
    }
  }
  match f {
    VectorSearch(scope~, id~, index_id~) => {
      guard eval(ctx, args[1]).as_int64() is Some(top) else {
        raise @types.sql_error(
          1014,
          "A TOP or FETCH clause contains an invalid value.",
          severity=15,
        )
      }
      if top < 0L {
        raise @types.sql_error(
          127,
          "A TOP N or FETCH rowcount value may not be negative.",
          severity=15,
        )
      }
      guard eval(ctx, args[0]) is Vector(query) else { return }
      let width = eval(ctx, args[2]).as_int64().unwrap_or(5L)
      let expansion = eval(ctx, args[3]).as_int64().unwrap_or(4L)
      for
        row in (ctx.vector_search)(
          scope, id, index_id, query, top, width, expansion,
        ) {
        emit(row)
      }
    }
    RegexMatches | RegexSplit => regex_table(ctx, f, args, emit)
    XmlNodes =>
      for r in xml_nodes_rows(ctx, args) {
        emit(r)
      }
    OpenJsonDefault => {
      let input = eval(ctx, args[0])
      guard open_input(input) is Some(doc) else { return }
      let path = if args.length() > 1 { text(1) } else { Some("$") }
      guard path is Some(path) else { return }
      if input is NativeJson(data) {
        data.validate_openjson(path)
      }
      let jt = args[0].ty is Json
      for r in json(() => @json.openjson(doc, path~, json_type=jt)) {
        emit([
          @types.Value::String(r.key),
          match r.value {
            Some(v) => String(v)
            None => Null
          },
          TinyInt(r.ty),
        ])
      }
    }
    OpenJsonWith(columns) => {
      let input = eval(ctx, args[0])
      guard open_input(input) is Some(doc) else { return }
      let path = if args.length() > 1 { text(1) } else { Some("$") }
      guard path is Some(path) else { return }
      if input is NativeJson(data) {
        data.validate_openjson(path)
      }
      let jt = args[0].ty is Json
      let all = json(() => @json.openjson(doc, path~, json_type=jt))
      // Native empty objects, like empty arrays, produce no WITH rows.
      if jt && all.is_empty() {
        return
      }
      // an object selection is one row; an array gives one row per element
      // (captured: query/table-functions step 2)
      let fragment = json(() => {
        if jt {
          @json.openjson_fragment(doc, path)
        } else {
          @json.json_query(doc, path~)
        }
      })
      let elements = match fragment {
        Some(t) if t.has_prefix("{") =>
          [@json.OpenJsonRow::{ key: "", value: Some(t), ty: 5, }]
        _ => all
      }
      for el in elements {
        let row : Row = []
        for c in columns {
          let v : @types.Value = match el.value {
            None => Null
            Some(item) =>
              // scalar elements are not JSON text; only containers have paths
              if el.ty == 4 || el.ty == 5 {
                let got = try {
                  if jt {
                    json(() => @json.openjson_column(item, c.path, c.as_json))
                  } else if c.as_json {
                    json(() => @json.json_query(item, path=c.path))
                  } else {
                    json(() => @json.json_value(item, c.path))
                  }
                } catch {
                  // captured (json4): strict column paths of a json
                  // document are 13608 state 8
                  @types.SqlError(number=13608, ..) if jt =>
                    raise @types.sql_error(
                      13608,
                      @json.MISSING_MESSAGE,
                      state=8,
                    )
                  e => raise e
                }
                // captured (json4): a json column without AS JSON over a
                // json document parses string values only (other scalars
                // are NULL); over character text every scalar converts
                let got = if jt &&
                  c.ty is Json &&
                  !c.as_json &&
                  json(() => @json.json_value_kind(item, c.path, native=jt)) !=
                  Some(1) {
                  None
                } else {
                  got
                }
                match got {
                  Some(s) =>
                    @types.cast(
                      String(s),
                      NVarChar(None, @types.default_collation),
                      c.ty,
                    )
                  None => Null
                }
              } else {
                Null
              }
          }
          row.push(v)
        }
        emit(row)
      }
    }
    StringSplit(ordinal~) => {
      let sep = text(1)
      match sep {
        Some(s) if s.length() == 1 => ()
        _ =>
          raise @types.sql_error(
            214,
            "Procedure expects parameter 'separator' of type 'nchar(1)/nvarchar(1)'.",
            state=11,
          )
      }
      guard text(0) is Some(s) else { return }
      let sep_unit = sep.unwrap().code_unit_at(0)
      let mut start = 0
      let mut n = 0L
      for i in 0..<=s.length() {
        if i == s.length() || s.code_unit_at(i) == sep_unit {
          n += 1L
          let part : @types.Value = String(s.unsafe_substring(start~, end=i))
          emit(if ordinal { [part, BigInt(n)] } else { [part] })
          start = i + 1
        }
      }
    }
    DiagnosticText(rows) => {
      let handle = eval(ctx, args[0])
      if !(handle is Null) {
        for row in rows {
          if row.get(5) == Some(handle) {
            emit(row[:5].to_owned())
          }
        }
      }
    }
    GenerateSeries(ty) => generate_series(ctx, ty, args, emit)
  }
}

///|
/// GENERATE_SERIES(start, stop [, step]): the binder converts every
/// argument to the `value` type; without a step it is 1 or -1 toward stop.
/// A step of the wrong sign gives no rows, any NULL argument none either,
/// and a zero step is error 4199 (captured: analytic/generate-series).
fn generate_series(
  ctx : Ctx,
  ty : @types.SqlType,
  args : Array[@ir.Expr],
  emit : (Row) -> Unit raise @types.SqlError,
) -> Unit raise @types.SqlError {
  let vals = args.map(a => eval(ctx, a))
  let zero_step = () => {
    @types.sql_error(
      4199,
      "Argument value 0 is invalid for argument 3 of generate_series function.",
      state=2,
    )
  }
  match ty {
    Decimal(_, sc) | Numeric(_, sc) => {
      let dec = (v : @types.Value) => {
        match v {
          Decimal(d) => Some(d.rescale(sc))
          _ => None
        }
      }
      guard dec(vals[0]) is Some(start) && dec(vals[1]) is Some(stop) else {
        return
      }
      let step = if vals.length() > 2 {
        match dec(vals[2]) {
          Some(st) => st
          None => return
        }
      } else if start.compare(stop) <= 0 {
        @types.Decimal::from_int64(1L).rescale(sc)
      } else {
        @types.Decimal::from_int64(-1L).rescale(sc)
      }
      if step.is_zero() {
        raise zero_step()
      }
      let mut cur = start
      while (step.sign() > 0 && cur.compare(stop) <= 0) ||
            (step.sign() < 0 && cur.compare(stop) >= 0) {
        ctx.rt.charge(1L)
        emit([Decimal(cur)])
        cur = cur.add(step).rescale(sc)
      }
    }
    _ => {
      guard vals[0].as_int64() is Some(start) &&
        vals[1].as_int64() is Some(stop) else {
        return
      }
      let step = if vals.length() > 2 {
        match vals[2].as_int64() {
          Some(st) => st
          None => return
        }
      } else if start <= stop {
        1L
      } else {
        -1L
      }
      if step == 0L {
        raise zero_step()
      }
      let mut cur = start
      while (step > 0L && cur <= stop) || (step < 0L && cur >= stop) {
        ctx.rt.charge(1L)
        emit([@types.int_value(ty, cur)])
        let next = cur + step
        // stop before the Int64 sum wraps (bigint at its limits)
        if (step > 0L && next < cur) || (step < 0L && next > cur) {
          break
        }
        cur = next
      }
    }
  }
}
