///|
/// xml data type methods (bound by bind/xml_methods.mbt as `Fn::Named`
/// calls "XML.VALUE", "XML.QUERY", "XML.EXIST" with arguments: the xml
/// value, the XQuery text, then the sql:variable / sql:column values) and
/// the nodes() table function. Captured: harness/corpus/xml/methods.

///|
/// Compiled XQuery texts (pure cache: compilation is deterministic).
let xquery_cache : Map[String, @xml.XPath] = Map([])

///|
fn compiled_xquery(
  meth : String,
  text : String,
) -> @xml.XPath raise @types.SqlError {
  let key = meth + "\u{0}" + text
  match xquery_cache.get(key) {
    Some(p) => p
    None => {
      let p = @xml.compile(text, meth) catch { e => raise @types.xml_error(e) }
      if xquery_cache.length() > 1000 {
        xquery_cache.clear()
      }
      xquery_cache.set(key, p)
      p
    }
  }
}

///|
/// A SQL value as sql:variable / sql:column passes it to XQuery.
fn xquery_ext(
  v : @types.Value,
  ty : @types.SqlType,
) -> @xml.Ext raise @types.SqlError {
  match v {
    Null => ExtNull
    Bit(b) => ExtBool(b)
    TinyInt(n) | SmallInt(n) | Int(n) => ExtNum(n.to_double())
    BigInt(n) => ExtNum(n.to_double())
    Float(d) => ExtNum(d)
    Decimal(_) | Money(_) =>
      match @types.cast(v, ty, Float) {
        Float(d) => ExtNum(d)
        _ => ExtNull
      }
    String(s) => ExtStr(s)
    Xml(x) => ExtStr(x.to_text())
    _ => ExtStr(@types.render(v, ty, None))
  }
}

///|
fn xquery_exts(
  v : Array[@types.Value],
  args : Array[@ir.Expr],
) -> Array[@xml.Ext] raise @types.SqlError {
  let out = []
  for i in 2..<v.length() {
    out.push(xquery_ext(v[i], args[i].ty))
  }
  out
}

///|
fn xml_call(
  f : () -> @types.Value raise @xml.XmlError,
) -> @types.Value raise @types.SqlError {
  f() catch {
    e => raise @types.xml_error(e)
  }
}

///|
/// The Named-function hook for xml methods (None: not an xml method).
fn call_xml_method(
  name : String,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value? raise @types.SqlError {
  let meth = match name {
    "XML.VALUE" => "value"
    "XML.QUERY" => "query"
    "XML.EXIST" => "exist"
    _ => return None
  }
  guard v[0] is Xml(x) else { return Some(Null) }
  guard v[1] is String(text) else { return Some(Null) }
  let p = compiled_xquery(meth, text)
  let ext = xquery_exts(v, args)
  let r = match meth {
    "value" =>
      match
        xml_call(() => {
          match @xml.value(x, p, ext~) {
            Some(s) => String(s)
            None => Null
          }
        }) {
        // SQL Server converts the atomized string as nvarchar (captured:
        // 245 "converting the nvarchar value 'a' to data type int")
        String(s) =>
          @types.cast(String(s), NVarChar(None, @types.default_collation), e.ty)
        _ => Null
      }
    "query" => xml_call(() => Xml(@xml.query(x, p, ext~)))
    _ => xml_call(() => Bit(@xml.exist(x, p, ext~)))
  }
  Some(r)
}

///|
/// nodes(): one row per result node, holding an xml context reference.
fn xml_nodes_rows(
  ctx : Ctx,
  args : Array[@ir.Expr],
) -> Array[Row] raise @types.SqlError {
  let v = args.map(a => eval(ctx, a))
  guard v[0] is Xml(x) else { return [] }
  guard v[1] is String(text) else { return [] }
  let p = compiled_xquery("nodes", text)
  let ext = xquery_exts(v, args)
  let refs = @xml.nodes(x, p, ext~) catch { e => raise @types.xml_error(e) }
  refs.map(r => [@types.Value::Xml(r)])
}

///|
/// FOR JSON in a subquery: the chunked text as one value (no rows for no
/// input). The DONE count of the statement is not touched.
fn run_concat(ctx : Ctx, inner : @ir.Plan) -> Array[Row] raise @types.SqlError {
  let rows = match inner {
    ForJson(
      input,
      columns,
      root~,
      include_nulls~,
      without_array_wrapper~,
      shape~
    ) =>
      run_for_json(
        run(ctx, input),
        columns,
        root,
        include_nulls,
        without_array_wrapper,
        shape,
      )
    other => run(ctx, other)
  }
  if rows.is_empty() {
    return []
  }
  let sb = StringBuilder()
  for r in rows {
    match r[0] {
      String(s) => sb.write_string(s)
      _ => ()
    }
  }
  [[String(sb.to_string())]]
}
