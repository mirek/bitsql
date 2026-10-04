// FOR JSON PATH / AUTO binding and the "is this JSON text" property of
// expressions. Captures: harness/corpus/query/for-json, json2/, msduck
// gaps-json_string, json-aggregates, unicode-json-storage.

///|
/// Whether SQL Server treats `e`'s text as JSON when embedding it (JSON_OBJECT,
/// JSON_ARRAY, JSON_MODIFY values, FOR JSON columns, the JSON aggregates):
/// results of JSON_QUERY, JSON_MODIFY, JSON_OBJECT, JSON_ARRAY, the JSON
/// aggregates and FOR JSON subqueries with the array wrapper, also through
/// columns of derived tables, CTEs and views (captured: msduck
/// json-aggregates#054). A WITHOUT_ARRAY_WRAPPER subquery, a variable
/// holding JSON_QUERY's result and JSON_VALUE are plain strings.
fn is_json_expr(env : Env, e : @ir.Expr) -> Bool {
  json_expr_in(e, (depth, i) => {
    let mut s = env
    for _ in 0..<depth {
      match s.outer {
        Some(o) => s = o
        None => return false
      }
    }
    match s.from_plan {
      Some(p) => json_plan_column(p, i)
      None => false
    }
  })
}

///|
fn json_expr_in(e : @ir.Expr, col : (Int, Int) -> Bool) -> Bool {
  match e.kind {
    Call(JsonQuery, _) => true
    Call(Named("JSON_MODIFY" | "JSON_OBJECT" | "JSON_ARRAY"), _) => true
    Subquery(p) => json_plan_column(p, 0)
    Col(i) => col(0, i)
    OuterCol(d, i) => col(d, i)
    _ => false
  }
}

///|
/// Whether output column `j` of a plan carries JSON text.
fn json_plan_column(plan : @ir.Plan, j : Int) -> Bool {
  match plan {
    Concat(p) => json_plan_column(p, 0)
    ForJson(_, _, without_array_wrapper~, ..) => !without_array_wrapper
    Project(p, exprs) =>
      j < exprs.length() &&
      json_expr_in(exprs[j], (depth, i) => depth == 0 && json_plan_column(p, i))
    Filter(p, _)
    | Sort(p, _)
    | Limit(p, _, _)
    | Distinct(p, _)
    | Top(p, _, ..)
    | NoNullWarning(p) => json_plan_column(p, j)
    Join(_, l, r, _, left_width~, ..) =>
      if j < left_width {
        json_plan_column(l, j)
      } else {
        json_plan_column(r, j - left_width)
      }
    Aggregate(p, keys, aggs, ..) =>
      if j < keys.length() {
        json_expr_in(keys[j], (depth, i) => depth == 0 && json_plan_column(p, i))
      } else {
        let k = j - keys.length()
        k < aggs.length() && is_json_agg(aggs[k])
      }
    _ => false
  }
}

///|
/// JSON_ARRAYAGG / JSON_OBJECTAGG calls (see bind/json_agg.mbt).
fn is_json_agg(a : @ir.AggCall) -> Bool {
  ignore(a)
  false
}

///|
/// A FROM source as FOR JSON AUTO names it: (lowercased qualifier, name as
/// written, whether it forms a level). Table-valued functions do not
/// (captured: STRING_SPLIT columns stay flat, gaps-json_string#036).
fn json_auto_sources(
  r : @ast.TableRef,
  out : Array[(String, String, Bool)],
) -> Unit {
  let add = (alias_ : @ast.Ident?, written : String, level : Bool) => {
    let name = match alias_ {
      Some(a) => a.name
      None => written
    }
    out.push((name.to_lower(), name, level))
  }
  match r.kind {
    Table(n, alias_~, ..) =>
      match alias_ {
        Some(a) => out.push((a.name.to_lower(), a.name, true))
        None =>
          out.push(
            (n.base().to_lower(), n.parts.map(p => p.name).join("."), true),
          )
      }
    TableVar(v, alias_~, ..) => add(alias_, v, true)
    Derived(_, alias_~, ..) => add(alias_, "", true)
    Values(_, alias_~, ..) => add(Some(alias_), "", true)
    TableFunc(n, _, alias_~, ..) => add(alias_, n.base(), false)
    Nodes(_, _, alias_~, ..) => add(alias_, "", false)
    Pivot(_, _, alias_~) => add(Some(alias_), "", true)
    Join(_, l, rr, ..) => {
      json_auto_sources(l, out)
      json_auto_sources(rr, out)
    }
  }
}

///|
/// FOR JSON AUTO: per output column its level, and the level names. A
/// column of a source opens that source's level the first time one
/// appears (the select list order defines the nesting); an expression
/// belongs to the level of the column before it, or the first level when
/// it leads (captured: gaps-json_string#019-#022). Set operations are flat.
fn json_auto_levels(
  env : Env,
  q : @ast.Query,
  ncols : Int,
) -> (Array[Int], Array[Bool], Array[String]) raise @types.SqlError {
  guard q.body is Select(s) else { return ([], [], []) }
  let sources = []
  for r in s.from {
    json_auto_sources(r, sources)
  }
  let (_, from_cols) = bind_from(with_ctes(env, q.ctes), s.from)
  let level_source = (qual : String) => {
    for t in sources {
      if t.0 == qual {
        return if t.2 { qual } else { "" }
      }
    }
    ""
  }
  // per output column: lowercased source qualifier, "" for expressions
  let quals : Array[String] = []
  for item in s.items {
    match item.kind {
      Star([]) =>
        for c in from_cols {
          quals.push(level_source(c.qualifier))
        }
      Star(parts) => {
        let t = parts[parts.length() - 1].name.to_lower()
        for c in from_cols {
          if c.qualifier == t {
            quals.push(level_source(c.qualifier))
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
        quals.push(level_source(found))
      }
      _ => quals.push("")
    }
  }
  if quals.length() != ncols {
    raise @types.not_supported("FOR JSON AUTO over this select list")
  }
  let order : Array[String] = []
  let names : Array[String] = []
  let levels = []
  let mut current = -1
  for qq in quals {
    if qq != "" {
      current = match order.search(qq) {
        Some(l) => l
        None => {
          order.push(qq)
          let mut name = qq
          for t in sources {
            if t.0 == qq {
              name = t.1
              break
            }
          }
          names.push(name)
          order.length() - 1
        }
      }
    }
    levels.push(current)
  }
  // leading expressions belong to the first level
  for i in 0..<levels.length() {
    if levels[i] < 0 {
      levels[i] = 0
    }
  }
  if names.length() <= 1 {
    return ([], [], [])
  }
  (levels, quals.map(q => q != ""), names)
}

///|
/// Binds `SELECT ... FOR JSON PATH|AUTO`. 13600 (AUTO without a table) and
/// 13620 (ROOT with WITHOUT_ARRAY_WRAPPER) are batch compile errors raised
/// by the session's precheck (session/precheck_json.mbt).
fn bind_for_json(
  env : Env,
  q : @ast.Query,
  mode : @ast.JsonMode,
  root : String?,
  include_null_values : Bool,
  without_array_wrapper : Bool,
) -> BoundQuery raise @types.SqlError {
  let bq = bind_query_inner(env, { ..q, for_clause: None, }, top_level=true)
  for c in bq.columns {
    if c.name == "" {
      raise err(
        13605, "Column expressions and data sources without names or aliases cannot be formatted as JSON text using FOR JSON clause. Add alias to the unnamed column or table.",
      )
    }
  }
  let (levels, keys, names) = if mode is JsonAuto {
    json_auto_levels(env, q, bq.columns.length())
  } else {
    ([], [], [])
  }
  let raw = bq.columns.mapi((j, _) => json_plan_column(bq.plan, j))
  {
    plan: ForJson(
      bq.plan,
      bq.columns,
      root~,
      include_nulls=include_null_values,
      without_array_wrapper~,
      shape={ raw, levels, keys, names, },
    ),
    columns: [
      {
        name: for_json_column,
        ty: NVarChar(None, env.collation),
        nullable: true,
        origin: SetOperation,
      },
    ],
    order: [],
  }
}
