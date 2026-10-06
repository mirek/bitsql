// The xml data type in the binder: method calls (value, query, exist,
// nodes, modify), the nodes() table, and the operand rules for xml values
// in comparisons and built-ins. Captured: harness/corpus/xml/type and
// methods (docs/reference/xml.md).

///|
fn xml_name_text(e : @ast.Expr) -> String {
  match e.kind {
    Column(parts) => parts.map(p => p.name).join(".")
    Var(v) => v
    _ => ""
  }
}

///|
/// Is `parts` a column of a nodes() table (usable only as a method target
/// or in IS [NOT] NULL)?
fn is_nodes_column(env : Env, parts : Array[@ast.Ident]) -> Bool {
  let name = parts[parts.length() - 1].name.to_lower()
  let qualifier = if parts.length() >= 2 {
    parts[parts.length() - 2].name.to_lower()
  } else {
    ""
  }
  let mut scope : Env? = Some(env)
  while scope is Some(s) {
    for c in s.columns {
      if c.name.to_lower() == name &&
        (qualifier == "" || c.qualifier == qualifier) {
        return c.origin is XmlNodes
      }
    }
    scope = s.outer
  }
  false
}

///|
fn nodes_column_error(name : String) -> @types.SqlError {
  err(
    493,
    "The column '\{name}' that was returned from the nodes() method cannot be used directly. It can only be used with one of the four XML data type methods, exist(), nodes(), query(), and value(), or in IS NULL and IS NOT NULL checks.",
  )
}

///|
/// A column reference in an ordinary expression: nodes() columns are 493.
fn bind_column_checked(
  env : Env,
  parts : Array[@ast.Ident],
) -> @ir.Expr raise @types.SqlError {
  let e = bind_column(env, parts)
  if e.ty is Xml && is_nodes_column(env, parts) {
    raise nodes_column_error(parts[parts.length() - 1].name)
  }
  e
}

///|
/// The target of a method call or IS NULL (nodes() columns allowed).
fn bind_xml_target(env : Env, e : @ast.Expr) -> @ir.Expr raise @types.SqlError {
  match e.kind {
    Column(parts) => bind_column(env, parts)
    _ => bind_expr(env, e)
  }
}

///|
fn xml_literal_arg(
  meth : String,
  args : Array[@ast.Expr],
  i : Int,
) -> String raise @types.SqlError {
  match args[i].kind {
    StrLit(s, ..) => s
    _ =>
      raise err(
        8172,
        "The argument \{i + 1} of the XML data type method \"\{meth}\" must be a string literal.",
      )
  }
}

///|
/// Parses a value() type argument (`'nvarchar(10)'`, `'decimal(5, 2)'`).
fn value_method_type(
  env : Env,
  text : String,
) -> @types.SqlType raise @types.SqlError {
  let invalid = () => {
    err(9500, "The data type '\{text}' used in the VALUE method is invalid.")
  }
  let t = text.trim().to_owned()
  let (name, rest) = match t.find("(") {
    Some(i) =>
      (
        t.unsafe_substring(start=0, end=i).trim().to_owned(),
        t.unsafe_substring(start=i, end=t.length()).trim().to_owned(),
      )
    None => (t, "")
  }
  let args : Array[@ast.TypeArg] = []
  if rest != "" {
    if !rest.has_suffix(")") {
      raise invalid()
    }
    let inner = rest.unsafe_substring(start=1, end=rest.length() - 1)
    for part in inner.split(",") {
      let p = part.trim().to_owned()
      if p.to_lower() == "max" {
        args.push(Max)
      } else if p != "" && p.iter().all(c => c >= '0' && c <= '9') {
        args.push(Num(p))
      } else {
        raise invalid()
      }
    }
  }
  match name.to_lower() {
    "xml"
    | "sql_variant"
    | "text"
    | "ntext"
    | "image"
    | "timestamp"
    | "rowversion" => raise invalid()
    _ => ()
  }
  let span : @ast.Span = { start: 0, end: 0, line: 0, col: 0, }
  let tn : @ast.TypeName = { schema: None, name, args, span, }
  resolve_type(
    tn,
    Conversion,
    env.collation,
    preview=(env.catalog.preview_features)(),
  ) catch {
    _ => raise invalid()
  }
}

///|
/// Compiles a method's XQuery text and binds its sql:variable /
/// sql:column references.
fn bind_xquery(
  env : Env,
  meth : String,
  text : String,
) -> (@xml.XPath, Array[@ir.Expr]) raise @types.SqlError {
  let p = @xml.compile(text, meth) catch { e => raise @types.xml_error(e) }
  let exts = []
  for x in p.externals() {
    let (is_col, name) = x
    let e = if is_col {
      let parts = name
        .split(".")
        .map(s => @ast.Ident::{
          name: s.to_owned(),
          quoted: false,
          span: { start: 0, end: 0, line: 0, col: 0, },
        })
        .to_array()
      bind_column(env, parts)
    } else {
      bind_expr(env, {
        kind: Var(name),
        span: { start: 0, end: 0, line: 0, col: 0, },
      })
    }
    exts.push(e)
  }
  (p, exts)
}

///|
/// `target.name(args)` in an expression.
fn bind_method_call(
  env : Env,
  target : @ast.Expr,
  name : @ast.Ident,
  args : Array[@ast.Expr],
) -> @ir.Expr raise @types.SqlError {
  // `schema.fn(...)` parsed as a column method: a function call when the
  // target is no column
  if target.kind is Column(parts) && resolve_column(env, parts) is None {
    let fname : @ast.ObjectName = { parts: parts + [name], span: target.span, }
    return bind_call(env, {
      name: fname,
      args,
      distinct: false,
      star: false,
      niladic: false,
      within_group: [],
      over: None,
    })
  }
  let t = bind_xml_target(env, target)
  if !(t.ty is Xml) {
    raise err(258, "Cannot call methods on \{t.ty.base_name()}.", severity=15)
  }
  check_xml_options(env)
  let meth = name.name
  match meth {
    "value" | "query" | "exist" => ()
    "modify" =>
      raise err(
        8137, "Incorrect use of the XML data type method 'modify'. A non-mutator method is expected in this context.",
      )
    "nodes" =>
      raise @types.not_supported(
        "the nodes() method outside FROM",
        number=@types.EMU_XML_NOT_SUPPORTED,
      )
    _ =>
      raise err(
        227,
        "\"\{meth}\" is not a valid function, property, or field.",
        severity=15,
      )
  }
  arity(meth, args, if meth == "value" { 2 } else { 1 })
  let text = xml_literal_arg(meth, args, 0)
  let (p, exts) = bind_xquery(env, meth, text)
  let lit = mk(
    Lit(String(text)),
    NVarChar(Some(@cmp.maximum(text.length(), 1)), env.collation),
    false,
  )
  match meth {
    "value" => {
      let ty = value_method_type(env, xml_literal_arg(meth, args, 1))
      p.check_singleton() catch {
        e => raise @types.xml_error(e)
      }
      mk(Call(Named("XML.VALUE"), [t, lit] + exts), ty, true)
    }
    "query" => {
      p.check_query() catch {
        e => raise @types.xml_error(e)
      }
      mk(Call(Named("XML.QUERY"), [t, lit] + exts), Xml, true)
    }
    _ => mk(Call(Named("XML.EXIST"), [t, lit] + exts), Bit, true)
  }
}

///|
/// `target.nodes('xquery') AS alias(column)` in FROM.
fn bind_nodes_ref(
  env : Env,
  target : @ast.Expr,
  args : Array[@ast.Expr],
  alias_ : @ast.Ident?,
  columns : Array[@ast.Ident],
) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
  let penv = plan_env(env)
  check_xml_options(env)
  let t = bind_xml_target(penv, target)
  if !(t.ty is Xml) {
    raise err(258, "Cannot call methods on \{t.ty.base_name()}.", severity=15)
  }
  guard alias_ is Some(a) && columns.length() == 1 else {
    raise err(
      318,
      "The table (and its columns) returned by a table-valued method need to be aliased.",
      state=0,
      severity=15,
    )
  }
  arity("nodes", args, 1)
  let text = xml_literal_arg("nodes", args, 0)
  let (_, exts) = bind_xquery(penv, "nodes", text)
  let lit = mk(
    Lit(String(text)),
    NVarChar(Some(@cmp.maximum(text.length(), 1)), env.collation),
    false,
  )
  ignore(xml_name_text(target))
  (
    TableFunc(XmlNodes, [t, lit] + exts),
    [
      {
        untyped_null: false,
        qualifier: a.name.to_lower(),
        name: columns[0].name,
        ty: Xml,
        nullable: false,
        origin: XmlNodes,
      },
    ],
  )
}

///|
/// Comparisons with xml (captured): xml with xml is 305, xml with another
/// type 402 naming the operator.
fn xml_compare_check(
  op_name : String,
  a : @ir.Expr,
  b : @ir.Expr,
) -> Unit raise @types.SqlError {
  if a.ty is Vector(_, _) || b.ty is Vector(_, _) {
    if (a.ty is Vector(_, _) && b.ty is Vector(_, _)) ||
      (
        op_name == "equal to" &&
        (a.ty.family() == FString || b.ty.family() == FString)
      ) {
      raise err(
        8117,
        "Operand data type vector is invalid for \{op_name} operator.",
      )
    }
    raise @types.not_supported("comparison between vectors and other types")
  }
  if a.ty is Xml && b.ty is Xml {
    raise xml_not_comparable()
  }
  // captured (json4/type-compare): json = json, NULLIF, joins: 13636
  // state 1; json against another type 402
  if a.ty is Json && b.ty is Json {
    raise json_not_comparable(1)
  }
  if a.ty is (Xml | Json) || b.ty is (Xml | Json) {
    raise err(
      402,
      "The data types \{a.ty.clash_name()} and \{b.ty.clash_name()} are incompatible in the \{op_name} operator.",
    )
  }
}

///|
fn xml_not_comparable() -> @types.SqlError {
  err(
    305, "The XML data type cannot be compared or sorted, except when using the IS NULL operator.",
  )
}

///|
/// 13636: json in a comparison (state 1) or a sort / grouping key (state 2).
fn json_not_comparable(state : Int) -> @types.SqlError {
  err(
    13636,
    "The JSON data type cannot be compared or sorted, except when using the IS NULL operator.",
    state~,
  )
}

///|
/// Built-ins with an xml argument: the ones that take any type accept it;
/// CONCAT converts to nvarchar (257, captured); DATALENGTH reports SQL
/// Server's internal binary size (emulator error); everything else is
/// 8116 (captured for LEN, UPPER; assumed for the rest).
fn xml_guard(
  env : Env,
  name : String,
  args : Array[@ast.Expr],
) -> Unit raise @types.SqlError {
  match name {
    "ISNULL"
    | "COALESCE"
    | "IIF"
    | "COUNT"
    | "COUNT_BIG"
    | "MIN"
    | "MAX"
    | "SUM"
    | "AVG"
    | "STRING_AGG" => return
    _ => ()
  }
  for i, a in args {
    if !may_be_xml(a) {
      continue
    }
    let ty = try bind_expr(env, a) catch {
      _ => continue
    } noraise {
      b => b.ty
    }
    if ty is Json {
      json_arg_check(env, name, args, i)
      continue
    }
    if !(ty is Xml) {
      continue
    }
    match name {
      "CHOOSE" if i > 0 => ()
      "CONCAT" | "CONCAT_WS" =>
        raise @types.implicit_conversion_error(
          Xml,
          NVarChar(Some(1), env.collation),
        )
      "SQL_VARIANT_PROPERTY" if i == 0 =>
        raise @types.type_clash_error(Xml, Variant)
      "DATALENGTH" =>
        raise @types.not_supported(
          "DATALENGTH of xml (SQL Server's internal binary size)",
          number=@types.EMU_XML_NOT_SUPPORTED,
        )
      // captured: GREATEST(xml, xml) is 8116 state 4 (like text/ntext),
      // CHECKSUM(xml) too (msduck hashbytes-checksum #061)
      "GREATEST" | "LEAST" | "CHECKSUM" =>
        raise bad_arg_type(ty, i + 1, name.to_lower(), state=4)
      _ => raise bad_arg_type(ty, i + 1, name.to_lower())
    }
  }
}

///|
/// A json-typed argument of a built-in (captured json4/type-compare): the
/// JSON functions, ISNULL/COALESCE/IIF/CHOOSE take it; CONCAT/CONCAT_WS
/// report 257 to (n)varchar, GREATEST/LEAST/CHECKSUM 8116 state 4,
/// SQL_VARIANT_PROPERTY 206, DATALENGTH accepts native storage, everything
/// else 8116.
fn json_arg_check(
  env : Env,
  name : String,
  args : Array[@ast.Expr],
  i : Int,
) -> Unit raise @types.SqlError {
  match name {
    "JSON_VALUE"
    | "JSON_QUERY"
    | "ISJSON"
    | "JSON_CONTAINS"
    | "JSON_PATH_EXISTS"
    | "JSON_MODIFY"
    | "NULLIF" => ()
    // constructor names carry their clauses ("JSON_OBJECT RETURNING JSON")
    _ if name.has_prefix("JSON_OBJECT") || name.has_prefix("JSON_ARRAY") => ()
    "CHOOSE" if i > 0 => ()
    "CONCAT" | "CONCAT_WS" => {
      let unicode = args
        .iter()
        .any(a => {
          (try bind_expr(env, a) catch {
            _ => None
          } noraise {
            b => Some(b.ty)
          })
          is Some(NChar(_, _) | NVarChar(_, _) | NText(_))
        })
      raise @types.implicit_conversion_error(
        Json,
        if unicode {
          NVarChar(Some(1), env.collation)
        } else {
          VarChar(Some(1), env.collation)
        },
      )
    }
    "SQL_VARIANT_PROPERTY" if i == 0 =>
      raise @types.type_clash_error(Json, Variant)
    "DATALENGTH" => ()
    "GREATEST" | "LEAST" | "CHECKSUM" =>
      raise bad_arg_type(Json, i + 1, name.to_lower(), state=4)
    // captured: the 8116 message spells TRIM as "Trim"
    "TRIM" => raise bad_arg_type(Json, i + 1, "Trim")
    _ => raise bad_arg_type(Json, i + 1, name.to_lower())
  }
}

///|
fn may_be_xml(e : @ast.Expr) -> Bool {
  match e.kind {
    Var(_) | Column(_) | Subquery(_) | Case(..) | MethodCall(_, _, _) => true
    Cast(_, tn, ..) | Convert(tn, _, ..) =>
      tn.name.to_lower() is ("xml" | "json")
    Paren(x) => may_be_xml(x)
    Call(_) => true
    _ => false
  }
}

///|
/// ORDER BY an xml value: 305 (captured: xml/type#047).
fn xml_sort_check(keys : Array[@ir.SortKey]) -> Unit raise @types.SqlError {
  for k in keys {
    if k.expr.ty is Vector(_, _) {
      raise vector_not_comparable()
    }
    if k.expr.ty is Xml {
      raise xml_not_comparable()
    }
    // captured (json4/type-compare): 13636 state 2
    if k.expr.ty is Json {
      raise json_not_comparable(2)
    }
  }
}

///|
/// SELECT DISTINCT over xml: 421 (captured: xml/type#048).
fn xml_distinct_check(
  columns : Array[@ir.ResultColumn],
) -> Unit raise @types.SqlError {
  for c in columns {
    if c.ty is (Xml | Json | Vector(_, _)) {
      raise err(
        421,
        "The \{c.ty.base_name()} data type cannot be selected as DISTINCT because it is not comparable.",
      )
    }
  }
}

///|
/// UNION / EXCEPT / INTERSECT over xml: 5335 (captured: xml/type#050).
fn xml_set_op_check(
  columns : Array[@ir.ResultColumn],
) -> Unit raise @types.SqlError {
  for c in columns {
    if c.ty is (Xml | Json | Vector(_, _)) {
      raise err(
        5335,
        "The data type \{c.ty.base_name()} cannot be used as an operand to the UNION, INTERSECT or EXCEPT operators because it is not comparable.",
      )
    }
  }
}
