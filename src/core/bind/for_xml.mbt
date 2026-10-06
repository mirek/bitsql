// FOR XML RAW / AUTO / PATH (top level and in subqueries) and FOR JSON in
// subqueries. Option and column-name errors are compile-time, as captured
// (harness/corpus/xml/path, raw-auto, subquery; docs/reference/xml.md).

///|
/// Column name of the top-level FOR XML text result (sent as NTEXT).
pub let for_xml_column : String = "XML_F52E2B61-18A1-11d1-B105-00805F49916B"

///|
fn xml_unsupported(what : String) -> @types.SqlError {
  @types.not_supported(what, number=@types.EMU_XML_NOT_SUPPORTED)
}

///|
/// The first character of `name` that is not allowed in an XML name
/// (`colon_ok`: ':' counts as allowed).
fn bad_xml_name_char(name : String, colon_ok : Bool) -> Int? {
  for i in 0..<name.length() {
    let c = name.code_unit_at(i).to_int()
    let ok = if i == 0 { @xml.is_name_start(c) } else { @xml.is_name_char(c) }
    if !ok || (c == 0x3A && !colon_ok) {
      return Some(c)
    }
  }
  if name == "" {
    return Some(0)
  }
  None
}

///|
fn invalid_xml_name(label : String, full : String, c : Int) -> @types.SqlError {
  let h = c.to_string(radix=16).to_upper()
  let pad = String::make(4 - @cmp.minimum(4, h.length()), '0')
  err(
    6850,
    "\{label} name '\{full}' contains an invalid XML identifier as required by FOR XML; '\{c.unsafe_to_char()}'(0x\{pad}\{h}) is the first character at fault.",
  )
}

///|
fn check_xml_name(label : String, name : String) -> Unit raise @types.SqlError {
  match bad_xml_name_char(name, true) {
    Some(c) => raise invalid_xml_name(label, name, c)
    None => ()
  }
}

///|
priv enum PathLeaf {
  PElem
  PAttr
  PContent
}

///|
/// Validates a FOR XML PATH column name; returns its element steps (the
/// value's own element included for plain names) and leaf kind.
fn path_column(
  name : String,
) -> (Array[String], PathLeaf) raise @types.SqlError {
  match name {
    "" | "*" | "node()" | "text()" | "data()" | "comment()" =>
      return ([], PContent)
    _ => ()
  }
  if name.has_prefix("processing-instruction(") && name.has_suffix(")") {
    return ([], PContent)
  }
  if name.has_prefix("/") || name.has_suffix("/") || name.contains("//") {
    raise err(
      6849,
      "FOR XML PATH error in column '\{name}' - '//' and leading and trailing '/' are not allowed in simple path expressions.",
    )
  }
  let parts = name.split("/").map(p => p.to_owned()).to_array()
  let elems = []
  let check = (part : String) => {
    match bad_xml_name_char(part, true) {
      Some(c) => raise invalid_xml_name("Column", name, c)
      None => ()
    }
    match part.find(":") {
      Some(i) =>
        raise err(
          6846,
          "XML name space prefix '\{part.unsafe_substring(start=0, end=i)}' declaration is missing for FOR XML column name '\{name}'.",
          state=4,
        )
      None => ()
    }
  }
  for i, part in parts {
    let last = i == parts.length() - 1
    if last {
      if part.has_prefix("@") && part.length() > 1 {
        check(part.unsafe_substring(start=1, end=part.length()))
        return (elems, PAttr)
      }
      match part {
        "text()" | "data()" | "*" | "node()" | "comment()" =>
          return (elems, PContent)
        _ => ()
      }
    }
    check(part)
    elems.push(part)
  }
  (elems, PElem)
}

///|
/// PATH static checks: attributes must precede content of their element
/// (6852), xml values cannot be attributes (6851), attributes need a row
/// element (6864).
fn check_path_columns(
  columns : Array[@ir.ResultColumn],
  row : String,
) -> Unit raise @types.SqlError {
  let stack : Array[(String, Bool)] = []
  let mut row_content = false
  for c in columns {
    let (elems, leaf) = path_column(c.name)
    let mut common = 0
    while common < elems.length() &&
          common < stack.length() &&
          stack[common].0 == elems[common] {
      common += 1
    }
    while stack.length() > common {
      ignore(stack.pop())
    }
    for k in common..<elems.length() {
      if stack.is_empty() {
        row_content = true
      } else {
        stack[stack.length() - 1] = (stack[stack.length() - 1].0, true)
      }
      stack.push((elems[k], false))
    }
    match leaf {
      PAttr => {
        if c.ty is Xml {
          raise err(
            6851,
            "Column '\{c.name}' has invalid data type for attribute-centric XML serialization in FOR XML PATH.",
          )
        }
        let has_content = if stack.is_empty() {
          if row == "" {
            raise row_omission_error()
          }
          row_content
        } else {
          stack[stack.length() - 1].1
        }
        if has_content {
          raise err(
            6852,
            "Attribute-centric column '\{c.name}' must not come after a non-attribute-centric sibling in XML hierarchy in FOR XML PATH.",
          )
        }
      }
      PElem | PContent =>
        if stack.is_empty() {
          row_content = true
        } else {
          stack[stack.length() - 1] = (stack[stack.length() - 1].0, true)
        }
    }
  }
}

///|
fn row_omission_error() -> @types.SqlError {
  err(
    6864, "Row tag omission (empty row tag name) cannot be used with attribute-centric FOR XML serialization.",
  )
}

///|
fn binary_url_error(name : String) -> @types.SqlError {
  err(
    6829,
    "FOR XML EXPLICIT and RAW modes currently do not support addressing binary data as URLs in column '\{name}'. Remove the column, or use the BINARY BASE64 mode, or create the URL directly using the 'dbobject/TABLE[@PK1=\"V1\"]/@COLUMN' syntax.",
  )
}

///|
/// A FROM table as FOR XML AUTO names it: (lowercased qualifier, element
/// name as written).
fn auto_tables(r : @ast.TableRef, out : Array[(String, String)]) -> Unit {
  let add = (alias_ : @ast.Ident?, written : String) => {
    let name = match alias_ {
      Some(a) => a.name
      None => written
    }
    out.push((name.to_lower(), name))
  }
  match r.kind {
    Table(n, alias_~, ..) => {
      let written = n.parts.map(p => p.name).join(".")
      match alias_ {
        Some(a) => out.push((a.name.to_lower(), a.name))
        None => out.push((n.base().to_lower(), written))
      }
    }
    TableVar(v, alias_~, ..) => add(alias_, v)
    Derived(_, alias_~, ..) => add(alias_, "")
    Values(_, alias_~, ..) => add(Some(alias_), "")
    TableFunc(n, _, alias_~, ..) => add(alias_, n.base())
    VectorSearch(v) => add(v.source_alias, v.table.base())
    Nodes(_, _, alias_~, ..) => add(alias_, "")
    Pivot(_, _, alias_~) => add(Some(alias_), "")
    Join(_, l, rr, ..) => {
      auto_tables(l, out)
      auto_tables(rr, out)
    }
  }
}

///|
/// FOR XML AUTO: the table level of every output column, and the level
/// element names (tables in order of their first column).
fn auto_levels(
  env : Env,
  q : @ast.Query,
  ncols : Int,
) -> (Array[String], Array[Int]) raise @types.SqlError {
  guard q.body is Select(s) else {
    raise xml_unsupported("FOR XML AUTO over set operations")
  }
  if s.from.is_empty() {
    raise err(
      6800, "FOR XML AUTO requires at least one table for generating XML tags. Use FOR XML RAW or add a FROM clause with a table name.",
    )
  }
  let tables = []
  for r in s.from {
    auto_tables(r, tables)
  }
  let (_, from_cols) = bind_from(with_ctes(env, q.ctes), s.from)
  // per output column: lowercased qualifier, "" for expressions
  let quals : Array[String] = []
  for item in s.items {
    match item.kind {
      Star([]) =>
        for c in from_cols {
          quals.push(c.qualifier)
        }
      Star(parts) => {
        let t = parts[parts.length() - 1].name.to_lower()
        for c in from_cols {
          if c.qualifier == t {
            quals.push(c.qualifier)
          }
        }
      }
      ExprItem({ kind: Column(parts), .. }, ..) => {
        let name = parts[parts.length() - 1].name.to_lower()
        let qual = if parts.length() >= 2 {
          parts[parts.length() - 2].name.to_lower()
        } else {
          ""
        }
        let mut found = ""
        for c in from_cols {
          if c.name.to_lower() == name && (qual == "" || c.qualifier == qual) {
            found = c.qualifier
            break
          }
        }
        quals.push(found)
      }
      _ => quals.push("")
    }
  }
  if quals.length() != ncols {
    raise xml_unsupported("FOR XML AUTO over this select list")
  }
  // expressions belong to the table of the column before them (or after)
  for i in 0..<quals.length() {
    if quals[i] == "" {
      let mut j = i - 1
      while j >= 0 && quals[j] == "" {
        j -= 1
      }
      if j >= 0 {
        quals[i] = quals[j]
      }
    }
  }
  for i in 0..<quals.length() {
    let k = quals.length() - 1 - i
    if quals[k] == "" {
      quals[k] = if k + 1 < quals.length() && quals[k + 1] != "" {
        quals[k + 1]
      } else {
        tables[0].0
      }
    }
  }
  let names : Array[String] = []
  let order : Array[String] = []
  let levels = []
  for qq in quals {
    let mut l = order.search(qq).unwrap_or(-1)
    if l < 0 {
      l = order.length()
      order.push(qq)
      let mut name = qq
      for t in tables {
        if t.0 == qq {
          name = t.1
          break
        }
      }
      if name == "" {
        raise err(
          6809, "Unnamed tables cannot be used as XML identifiers as well as unnamed columns cannot be used for attribute names. Name unnamed columns/tables using AS in the SELECT statement.",
        )
      }
      names.push(@exec.encode_xml_name(name))
    }
    levels.push(l)
  }
  (names, levels)
}

///|
/// Binds a query with FOR XML. `top_level`: the statement's result (NTEXT
/// text chunks or an unnamed xml column) rather than a subquery value.
fn bind_for_xml(
  env : Env,
  q : @ast.Query,
  top_level : Bool,
) -> BoundQuery raise @types.SqlError {
  guard q.for_clause is Some(ForXml(mode~, element~, options~)) else {
    raise xml_unsupported("FOR BROWSE")
  }
  let mode : @ir.XmlMode = match mode {
    "RAW" => XmlRaw
    "AUTO" => XmlAuto
    "PATH" => XmlPath
    _ => raise xml_unsupported("FOR XML EXPLICIT")
  }
  let mut root : String? = None
  let mut elements = false
  let mut xsinil = false
  let mut type_ = false
  let mut base64 = false
  for o in options {
    if o == "TYPE" {
      type_ = true
    } else if o == "ELEMENTS" || o == "ELEMENTS ABSENT" {
      elements = true
    } else if o == "ELEMENTS XSINIL" {
      elements = true
      xsinil = true
    } else if o == "BINARY BASE64" {
      base64 = true
    } else if o == "ROOT" {
      root = Some("root")
    } else if o.has_prefix("ROOT('") {
      root = Some(o.unsafe_substring(start=6, end=o.length() - 2))
    } else if o.has_prefix("XMLSCHEMA") || o == "XMLDATA" {
      if mode is XmlPath {
        raise err(6855, "Inline schema is not supported with FOR XML PATH.")
      }
      raise xml_unsupported("FOR XML \{o}")
    } else {
      raise xml_unsupported("FOR XML option \{o}")
    }
  }
  if mode is XmlAuto && element is Some(_) {
    raise err(
      6859,
      "Row tag name is only allowed with RAW or PATH mode of FOR XML.",
      severity=15,
    )
  }
  let row = match element {
    Some(r) => r
    None => if mode is XmlAuto { "" } else { "row" }
  }
  if mode is XmlRaw && row == "" && !elements {
    raise row_omission_error()
  }
  if row != "" {
    check_xml_name("Row", row)
  }
  match root {
    Some(r) => check_xml_name("ROOT", r)
    None => ()
  }
  let bq = bind_query_inner(env, { ..q, for_clause: None, }, top_level=true)
  let cols = bq.columns
  let mut auto_names = []
  let mut auto_lvls = []
  match mode {
    XmlPath => check_path_columns(cols, row)
    XmlRaw => {
      if row == "" && !elements {
        raise row_omission_error()
      }
      if !elements {
        for i, c in cols {
          if c.name == "" {
            raise err(
              6809, "Unnamed tables cannot be used as XML identifiers as well as unnamed columns cannot be used for attribute names. Name unnamed columns/tables using AS in the SELECT statement.",
            )
          }
          if c.ty is Xml {
            continue
          }
          for j in 0..<i {
            if cols[j].name == c.name && !(cols[j].ty is Xml) {
              raise err(
                6810,
                "Column name '\{c.name}' is repeated. The same attribute cannot be generated more than once on the same XML tag.",
              )
            }
          }
        }
      }
      for c in cols {
        if c.ty.family() is FBinary && !base64 {
          raise binary_url_error(c.name)
        }
      }
    }
    XmlAuto => {
      for c in cols {
        if c.ty.family() is FBinary && !base64 {
          raise xml_unsupported(
            "FOR XML AUTO binary columns without BINARY BASE64",
          )
        }
        if c.name == "" {
          raise err(
            6809, "Unnamed tables cannot be used as XML identifiers as well as unnamed columns cannot be used for attribute names. Name unnamed columns/tables using AS in the SELECT statement.",
          )
        }
      }
      let (n, l) = auto_levels(env, q, cols.length())
      auto_names = n
      auto_lvls = l
    }
  }
  let spec : @ir.ForXmlSpec = {
    mode,
    row,
    root,
    elements,
    xsinil,
    type_,
    top_level,
    auto_names,
    auto_levels: auto_lvls,
  }
  let ty : @types.SqlType = if type_ {
    Xml
  } else {
    NVarChar(None, env.collation)
  }
  let name = if top_level && !type_ { for_xml_column } else { "" }
  {
    plan: ForXml(bq.plan, cols, spec, chunked=top_level && !type_),
    columns: [
      {
        name,
        ty,
        nullable: true,
        origin: if top_level {
          SetOperation
        } else {
          Computed
        },
      },
    ],
    order: [],
  }
}

///|
/// FOR XML / FOR JSON in a subquery, derived table or CTE: one value
/// (nvarchar(max), or xml with TYPE), NULL without input rows.
fn bind_for_subquery(
  env : Env,
  q : @ast.Query,
) -> BoundQuery raise @types.SqlError {
  match q.for_clause {
    Some(ForJson(..)) => {
      let bq = bind_query(env, q, result_columns=false)
      {
        plan: Concat(bq.plan),
        columns: [
          {
            name: "",
            ty: NVarChar(None, env.collation),
            nullable: true,
            origin: Computed,
          },
        ],
        order: [],
      }
    }
    _ => bind_for_xml(env, q, false)
  }
}
