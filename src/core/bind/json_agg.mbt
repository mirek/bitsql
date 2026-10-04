// JSON_ARRAYAGG / JSON_OBJECTAGG (SQL Server 2025). The parser appends a
// clause marker argument (parse/json_ctor.mbt `json_agg`). Captures: msduck
// json-aggregates.

///|
/// The clause marker of a parsed JSON aggregate call, and the call's other
/// arguments.
fn json_agg_parts(call : @ast.FuncCall) -> (String?, Array[@ast.Expr]) {
  match call.args.last() {
    Some({ kind: StrLit(s, ..), .. }) if s.has_prefix(@ast.JSON_AGG_MARKER) =>
      (
        Some(
          s.unsafe_substring(
            start=@ast.JSON_AGG_MARKER.length(),
            end=s.length(),
          ),
        ),
        call.args[:call.args.length() - 1].to_owned(),
      )
    _ => (None, call.args)
  }
}

///|
/// The aggregate function of a JSON aggregate call over `value` (bound).
fn json_agg_fn(
  env : Env,
  name : String,
  call : @ast.FuncCall,
  value : @ir.Expr,
) -> @ir.AggFn {
  let (marker, _) = json_agg_parts(call)
  let clauses = marker.unwrap_or("N")
  // captured (json4/returning, msduck json-aggregates#025/#055/#102): the
  // result is the json type with RETURNING JSON or a json-typed value
  let json = clauses.contains("J") || value.ty is Json
  let absent = clauses.has_prefix("A")
  let raw = is_json_expr(env, value)
  if name == "JSON_OBJECTAGG" {
    JsonObjectAgg(absent~, raw~, json~)
  } else {
    JsonArrayAgg(absent~, raw~, json~)
  }
}

///|
/// Result type of a JSON aggregate function.
fn json_agg_type(env : Env, f : @ir.AggFn) -> @types.SqlType {
  match f {
    JsonArrayAgg(json=true, ..) | JsonObjectAgg(json=true, ..) => Json
    _ => NVarChar(None, env.collation)
  }
}

///|
/// Checks the shape of a JSON aggregate call and binds its key (OBJECTAGG)
/// and value.
fn bind_json_agg_args(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> (@ir.Expr?, @ir.Expr) raise @types.SqlError {
  let (marker, args) = json_agg_parts(call)
  let object = name == "JSON_OBJECTAGG"
  // captured: JSON_OBJECTAGG(k, v) and two k:v pairs are 174
  if object && (marker is None || args.length() != 2) {
    raise err(
      174,
      "The JSON_OBJECTAGG function requires 1 argument(s).",
      severity=15,
    )
  }
  // captured: JSON_ARRAYAGG(DISTINCT v) is 313 state 2
  if call.distinct {
    raise err(
      313,
      "An insufficient number of arguments were supplied for the procedure or function \{name.to_lower()}.",
      state=2,
    )
  }
  if !object && args.length() != 1 {
    raise err(
      174,
      "The JSON_ARRAYAGG function requires 1 argument(s).",
      severity=15,
    )
  }
  if object {
    (Some(bind_expr(env, args[0])), bind_expr(env, args[1]))
  } else {
    (None, bind_expr(env, args[0]))
  }
}

///|
/// Binds `JSON_ARRAYAGG(...)` / `JSON_OBJECTAGG(...)` as a grouped
/// aggregate: nvarchar(max), NULL over no rows.
fn bind_json_agg(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.AggCall raise @types.SqlError {
  let (key, value) = bind_json_agg_args(env, name, call)
  check_aggregate_order(env, call.within_group, constants=false)
  let order = call.within_group.map(o => {
    let k = bind_expr(env, o.expr)
    @ir.SortKey::{ expr: k, desc: o.desc, collation: k.ty.collation(), }
  })
  let func = json_agg_fn(env, name, call, value)
  {
    func,
    arg: Some(value),
    separator: key,
    distinct: false,
    order,
    ty: json_agg_type(env, func),
  }
}

///|
/// JSON_ARRAYAGG / JSON_OBJECTAGG (...) OVER (...): a running array or
/// object (captured: msduck json-aggregates#062, json3/json-aggregates).
/// The window arguments are the value and, for JSON_OBJECTAGG, the key.
fn bind_json_agg_window(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> (@ir.WinFn, Array[@ir.Expr]) raise @types.SqlError {
  if !call.within_group.is_empty() {
    raise @types.not_supported("ordered JSON_ARRAYAGG with OVER")
  }
  let (key, value) = bind_json_agg_args(env, name, call)
  let args = match key {
    Some(k) => [value, k]
    None => [value]
  }
  // captured (json4/returning): the windowed form stays nvarchar(max) even
  // with RETURNING JSON
  let f : @ir.AggFn = match json_agg_fn(env, name, call, value) {
    JsonArrayAgg(absent~, raw~, ..) => JsonArrayAgg(absent~, raw~, json=false)
    JsonObjectAgg(absent~, raw~, ..) => JsonObjectAgg(absent~, raw~, json=false)
    other => other
  }
  (Agg(f, distinct=false), args)
}

///|
/// The aggregates of one GROUP BY scope: an unordered JSON aggregate sees
/// the rows in the order of the scope's ordered aggregate (all orders of a
/// scope agree, 8711; captured: msduck json-aggregates#072, where
/// JSON_OBJECTAGG next to JSON_ARRAYAGG(n ORDER BY seq) lists keys by seq).
fn scope_ordered_aggs(aggs : Array[@ir.AggCall]) -> Array[@ir.AggCall] {
  let order = match aggs.iter().find_first(a => !a.order.is_empty()) {
    Some(a) => a.order
    None => return aggs
  }
  aggs.map(a => {
    if a.order.is_empty() && a.func is (JsonArrayAgg(..) | JsonObjectAgg(..)) {
      { ..a, order, }
    } else {
      a
    }
  })
}
