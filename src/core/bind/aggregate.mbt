///|
/// Aggregate and window-function binding: result types (captured in
/// harness/corpus/query/aggregate-basics, window-functions, string-agg,
/// msduck decimal-avg).

///|
fn invalid_operand(ty : @types.SqlType, op : String) -> @types.SqlError {
  err(
    8117,
    "Operand data type \{ty.base_name()} is invalid for \{op} operator.",
  )
}

///|
/// Result type of an aggregate over an argument of type `arg`.
fn agg_result_type(
  f : @ir.AggFn,
  arg : @types.SqlType?,
  env : Env,
) -> @types.SqlType raise @types.SqlError {
  match (f, arg) {
    (Count, _) => Int
    (CountBig, _) => BigInt
    (Grouping(_), _) => TinyInt
    (GroupingId(_), _) => Int
    (Sum | Avg, Some(t)) => {
      let op = if f is Sum { "sum" } else { "avg" }
      match t {
        TinyInt | SmallInt | Int => Int
        BigInt => BigInt
        Decimal(_, s) =>
          if f is Sum {
            Decimal(38, s)
          } else {
            Decimal(38, if s > 6 { s } else { 6 })
          }
        Numeric(_, s) =>
          if f is Sum {
            Numeric(38, s)
          } else {
            Numeric(38, if s > 6 { s } else { 6 })
          }
        Money | SmallMoney => Money
        Float | Real => Float
        other => raise invalid_operand(other, op)
      }
    }
    (Min | Max, Some(t)) =>
      match t {
        // captured: xml/type (MAX(xml) is 8117)
        Bit | Xml | Json =>
          raise invalid_operand(t, if f is Min { "min" } else { "max" })
        _ => t
      }
    (StringAgg, Some(t)) =>
      match t {
        // captured: 8116 (variant/functions.sql, msduck string-agg#022)
        Variant | Xml | Json | Binary(_) | VarBinary(_) | RowVersion =>
          raise bad_arg_type(t, 1, "string_agg")
        VarChar(None, _) | NVarChar(None, _) => t
        NChar(_, c) | NVarChar(_, c) => NVarChar(Some(4000), c)
        Char(_, c) | VarChar(_, c) => VarChar(Some(8000), c)
        _ => NVarChar(Some(4000), env.collation)
      }
    (Stdev | StdevP | Var | VarP, Some(t)) =>
      match t.family() {
        FInteger | FDecimal | FMoney | FFloat => Float
        // captured: the operator is named after the function
        // (variant/functions.sql: "... invalid for varp operator.")
        _ =>
          raise invalid_operand(
            t,
            match f {
              StdevP => "stdevp"
              Var => "var"
              VarP => "varp"
              _ => "stdev"
            },
          )
      }
    // captured: int only (bigint, smallint, tinyint are 8117 too)
    (ChecksumAgg, Some(t)) =>
      match t {
        Int => Int
        _ => raise invalid_operand(t, "checksum_agg")
      }
    (ApproxCountDistinct, Some(_)) => BigInt
    _ => raise @types.not_supported("aggregate shape")
  }
}

///|
fn agg_fn(name : String) -> @ir.AggFn? {
  match name {
    "COUNT" => Some(Count)
    "COUNT_BIG" => Some(CountBig)
    "SUM" => Some(Sum)
    "AVG" => Some(Avg)
    "MIN" => Some(Min)
    "MAX" => Some(Max)
    "STRING_AGG" => Some(StringAgg)
    "STDEV" => Some(Stdev)
    "STDEVP" => Some(StdevP)
    "VAR" => Some(Var)
    "VARP" => Some(VarP)
    "CHECKSUM_AGG" => Some(ChecksumAgg)
    "APPROX_COUNT_DISTINCT" => Some(ApproxCountDistinct)
    _ => None
  }
}

///|
fn nested_aggregate_error() -> @types.SqlError {
  err(
    130,
    "Cannot perform an aggregate function on an expression containing an aggregate or a subquery.",
    severity=15,
  )
}

///|
/// Binds an aggregate call whose arguments read the pre-aggregation row
/// (`env`).
fn bind_agg_call(
  env : Env,
  call : @ast.FuncCall,
) -> @ir.AggCall raise @types.SqlError {
  let name = call.name.base().to_upper()
  if name is ("JSON_ARRAYAGG" | "JSON_OBJECTAGG") {
    for a in call.args {
      if any_expr(a, x => is_aggregate(x) || is_window(x), subqueries=true) {
        raise nested_aggregate_error()
      }
    }
    return bind_json_agg(env, name, call)
  }
  let f = match agg_fn(name) {
    Some(f) => f
    None => raise @types.not_supported("aggregate \{name}")
  }
  // 8117 for a NULL literal argument comes before 130 (captured:
  // SUM(COUNT(NULL)) is 8117 "… for count operator")
  match null_aggregate({ kind: Call(call), span: call.name.span, }) {
    Some(n) =>
      raise err(8117, "Operand data type NULL is invalid for \{n} operator.")
    None => ()
  }
  for a in call.args {
    if any_expr(a, x => is_aggregate(x) || is_window(x), subqueries=true) {
      raise nested_aggregate_error()
    }
  }
  if !call.within_group.is_empty() && !(f is StringAgg) {
    raise @types.not_supported("WITHIN GROUP for \{name}")
  }
  if f is ApproxCountDistinct && call.distinct {
    raise err(
      16200,
      "The statement failed because 'APPROX_COUNT_DISTINCT' does not support DISTINCT <column-name> parameters. Consider using 'APPROX_COUNT_DISTINCT' without DISTINCT, or COUNT or COUNT_BIG with DISTINCT.",
      severity=15,
    )
  }
  let (arg, separator) = if call.star {
    (None, None)
  } else if f is StringAgg {
    agg_arity(name, call.args, 2)
    let x = bind_expr(env, call.args[0])
    let sep = bind_expr(env, call.args[1])
    if sep.ty is Variant && !(x.ty is Variant) {
      raise bad_arg_type(sep.ty, 2, "string_agg")
    }
    check_string_agg_separator(x, call.args[1], sep)
    check_aggregate_order(env, call.within_group, constants=false)
    (Some(x), Some(sep))
  } else {
    agg_arity(name, call.args, 1)
    (Some(bind_expr(env, call.args[0])), None)
  }
  // captured: MIN/MAX/COUNT/SUM over the NULL constant, also a derived
  // table's NULL column, is 8117; STRING_AGG 8116 (query/derived-untyped-null)
  if arg is Some(a) && is_untyped_null(a) && !call.distinct {
    match f {
      StringAgg =>
        raise err(
          8116, "Argument data type NULL is invalid for argument 1 of string_agg function.",
        )
      Count | CountBig | Sum | Avg | Min | Max =>
        raise err(
          8117,
          "Operand data type NULL is invalid for \{name.to_lower()} operator.",
        )
      _ => ()
    }
  }
  // captured: MIN/MAX/COUNT/… of text, ntext or image is 8117 (COUNT
  // DISTINCT state 2); STRING_AGG is 8116
  // captured (json4/type-compare): COUNT(DISTINCT json) is 8117 state 2
  // (COUNT(json) works)
  if arg is Some(a) && a.ty is Json && call.distinct {
    raise err(
      8117,
      "Operand data type json is invalid for \{name.to_lower()} operator.",
      state=2,
    )
  }
  if arg is Some(a) && a.ty.is_lob() {
    if f is StringAgg {
      raise bad_arg_type(a.ty, 1, "string_agg")
    }
    raise err(
      8117,
      "Operand data type \{a.ty.base_name()} is invalid for \{name.to_lower()} operator.",
      // APPROX_COUNT_DISTINCT is state 2 like COUNT(DISTINCT) (captured:
      // analytic/approx-checksum-gaps)
      state=if call.distinct || f is ApproxCountDistinct { 2 } else { 1 },
    )
  }
  let ty = agg_result_type(f, arg.map(a => a.ty), env)
  // captured probe: MAX(CASE .. a ELSE b END) over two implicit collations
  // is 4191 "for max operation"
  if f is (Min | Max) && arg is Some(a) {
    ignore(resolve_collation(env, name.to_lower(), [a]))
  }
  let order = call.within_group.map(o => {
    let k = bind_expr(env, o.expr)
    @ir.SortKey::{ expr: k, desc: o.desc, collation: k.ty.collation(), }
  })
  { func: f, arg, separator, distinct: call.distinct, order, ty, }
}

///|
fn bind_frame_bound(
  env : Env,
  b : @ast.FrameBound,
) -> @ir.FrameBound raise @types.SqlError {
  match b {
    UnboundedPreceding => UnboundedPreceding
    UnboundedFollowing => UnboundedFollowing
    CurrentRow => CurrentRow
    Preceding(e) => Preceding(coerce(bind_expr(env, e), BigInt))
    Following(e) => Following(coerce(bind_expr(env, e), BigInt))
  }
}

///|
/// Binds a windowed call (`f(...) OVER (...)`) against the rows the window
/// sees (`env`: FROM columns, or grouped columns after GROUP BY).
fn bind_window_call(
  env : Env,
  call : @ast.FuncCall,
) -> @ir.WindowCall raise @types.SqlError {
  let name = call.name.base().to_upper()
  let over = call.over.unwrap()
  let partition = over.partition_by.map(p => bind_expr(env, p))
  let order = over.order_by.map(o => {
    let k = bind_expr(env, o.expr)
    @ir.SortKey::{ expr: k, desc: o.desc, collation: k.ty.collation(), }
  })
  // captured (json4/type-compare): json PARTITION BY / ORDER BY keys are
  // 13636 state 2
  if partition.iter().any(p => p.ty is Json) ||
    order.iter().any(k => k.expr.ty is Json) {
    raise json_not_comparable(2)
  }
  let needs_order = () => {
    if order.is_empty() {
      raise err(
        4112,
        "The function '\{name}' must have an OVER clause with ORDER BY.",
        severity=15,
      )
    }
  }
  let frame = match over.frame {
    None => None
    Some(fr) => {
      check_frame(name, over, fr)
      Some(@ir.WindowFrame::{
        rows: fr.unit is Rows,
        start: bind_frame_bound(env, fr.start),
        end: match fr.end {
          Some(e) => bind_frame_bound(env, e)
          None => CurrentRow
        },
      })
    }
  }
  let ignore_nulls = over.ignore_nulls
  if ignore_nulls && !(name is ("LAG" | "LEAD" | "FIRST_VALUE" | "LAST_VALUE")) {
    raise @types.not_supported("IGNORE NULLS with \{name}")
  }
  let mk_call = (f : @ir.WinFn, args : Array[@ir.Expr], ty : @types.SqlType) => @ir.WindowCall::{
    func: f,
    args,
    partition,
    partition_collations: partition.map(p => p.ty.collation()),
    order,
    frame,
    ty,
    ignore_nulls,
  }
  match name {
    "PERCENTILE_CONT" | "PERCENTILE_DISC" =>
      bind_percentile(env, name, call, partition)
    "ROW_NUMBER" | "RANK" | "DENSE_RANK" => {
      arity(name, call.args, 0)
      needs_order()
      let f : @ir.WinFn = match name {
        "ROW_NUMBER" => RowNumber
        "RANK" => Rank
        _ => DenseRank
      }
      mk_call(f, [], BigInt)
    }
    "NTILE" => {
      arity(name, call.args, 1)
      needs_order()
      let x = bind_expr(env, call.args[0])
      // captured: a column of the query itself is 4195 (ntile-null #008)
      if x.kind is Col(i) && i < env.columns.length() {
        raise err(
          4195,
          "The reference to column \"\{env.columns[i].name}\" is not allowed in an argument to the NTILE function. Only references to columns at an outer scope or standalone expressions and subqueries are allowed here.",
          severity=15,
        )
      }
      // captured (msduck ntile-types, ntile-null): only tinyint..bigint
      // are accepted, and a constant NULL or count below 1 is rejected at
      // compile time (also over no rows): 4116, severity 15
      let ok = x.ty is (TinyInt | SmallInt | Int | BigInt) &&
        !is_null_lit(x) &&
        (match try_fold(x) {
          Some(Null) => false
          Some(v) =>
            match v.as_int64() {
              Some(n) => n > 0L
              None => true
            }
          None => true
        })
      if !ok {
        raise ntile_error()
      }
      mk_call(Ntile, [coerce(x, BigInt)], BigInt)
    }
    "PERCENT_RANK" | "CUME_DIST" => {
      arity(name, call.args, 0)
      needs_order()
      mk_call(
        if name == "PERCENT_RANK" {
          PercentRank
        } else {
          CumeDist
        },
        [],
        Float,
      )
    }
    "LAG" | "LEAD" => {
      arity_range(name, call.args, 1, 3)
      needs_order()
      let v = bind_expr(env, call.args[0])
      let args = [v]
      if call.args.length() > 1 {
        args.push(coerce(bind_expr(env, call.args[1]), BigInt))
      }
      if call.args.length() > 2 {
        args.push(coerce(bind_expr(env, call.args[2]), v.ty))
      }
      mk_call(if name == "LAG" { Lag } else { Lead }, args, v.ty)
    }
    "FIRST_VALUE" | "LAST_VALUE" => {
      arity(name, call.args, 1)
      needs_order()
      let v = bind_expr(env, call.args[0])
      mk_call(
        if name == "FIRST_VALUE" {
          FirstValue
        } else {
          LastValue
        },
        [v],
        v.ty,
      )
    }
    "JSON_ARRAYAGG" | "JSON_OBJECTAGG" => {
      let (f, args) = bind_json_agg_window(env, name, call)
      let ty = match f {
        Agg(a, ..) => json_agg_type(env, a)
        _ => NVarChar(None, env.collation)
      }
      mk_call(f, args, ty)
    }
    _ =>
      match agg_fn(name) {
        // captured: analytic/string-agg-checks, approx-checksum-agg
        Some(StringAgg | ApproxCountDistinct) =>
          raise err(
            4113,
            "The function '\{name}' is not a valid windowing function, and cannot be used with the OVER clause.",
            state=if name == "STRING_AGG" { 4 } else { 5 },
            severity=15,
          )
        None =>
          // captured: msduck error-function-metadata#005
          raise err(
            4113,
            "The function '\{name}' is not a valid windowing function, and cannot be used with the OVER clause.",
            state=6,
            severity=15,
          )
        Some(f) => {
          if call.distinct {
            raise err(
              10759,
              "Use of DISTINCT is not allowed with the OVER clause.",
              severity=15,
            )
          }
          let args = if call.star {
            []
          } else {
            agg_arity(name, call.args, 1)
            [bind_expr(env, call.args[0])]
          }
          let ty = agg_result_type(f, args.get(0).map(a => a.ty), env)
          mk_call(Agg(f, distinct=false), args, ty)
        }
      }
  }
}

///|
/// 4116: NTILE's bucket count is not a positive integer (severity 15).
fn ntile_error() -> @types.SqlError {
  err(
    4116,
    "The function 'ntile' takes only a positive int or bigint expression as its input.",
    severity=15,
  )
}
