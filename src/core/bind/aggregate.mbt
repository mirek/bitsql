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
        Bit => raise invalid_operand(t, if f is Min { "min" } else { "max" })
        _ => t
      }
    (StringAgg, Some(t)) =>
      match t {
        VarChar(None, _) | NVarChar(None, _) => t
        NChar(_, c) | NVarChar(_, c) => NVarChar(Some(4000), c)
        Char(_, c) | VarChar(_, c) => VarChar(Some(8000), c)
        _ => NVarChar(Some(4000), env.collation)
      }
    (Stdev | StdevP | Var | VarP, Some(t)) =>
      match t.family() {
        FInteger | FDecimal | FMoney | FFloat => Float
        _ => raise invalid_operand(t, "stdev")
      }
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
  let f = match agg_fn(name) {
    Some(f) => f
    None => raise @types.not_supported("aggregate \{name}")
  }
  for a in call.args {
    if any_expr(a, x => is_aggregate(x) || is_window(x), subqueries=true) {
      raise nested_aggregate_error()
    }
  }
  if !call.within_group.is_empty() && !(f is StringAgg) {
    raise @types.not_supported("WITHIN GROUP for \{name}")
  }
  let (arg, separator) = if call.star {
    (None, None)
  } else if f is StringAgg {
    arity(name, call.args, 2)
    (Some(bind_expr(env, call.args[0])), Some(bind_expr(env, call.args[1])))
  } else {
    arity(name, call.args, 1)
    (Some(bind_expr(env, call.args[0])), None)
  }
  let ty = agg_result_type(f, arg.map(a => a.ty), env)
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
      if !(fr.unit is Rows) &&
        (
          fr.start is (Preceding(_) | Following(_)) ||
          fr.end is Some(Preceding(_) | Following(_))
        ) {
        raise @types.not_supported("RANGE window frames with offsets")
      }
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
  let mk_call = (f : @ir.WinFn, args : Array[@ir.Expr], ty : @types.SqlType) => @ir.WindowCall::{
    func: f,
    args,
    partition,
    partition_collations: partition.map(p => p.ty.collation()),
    order,
    frame,
    ty,
  }
  match name {
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
      mk_call(Ntile, [coerce(bind_expr(env, call.args[0]), BigInt)], BigInt)
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
    _ =>
      match agg_fn(name) {
        Some(StringAgg) | None =>
          raise @types.not_supported("window function \{name}")
        Some(f) => {
          if call.distinct {
            raise @types.not_supported("DISTINCT in windowed aggregates")
          }
          let args = if call.star {
            []
          } else {
            arity(name, call.args, 1)
            [bind_expr(env, call.args[0])]
          }
          let ty = agg_result_type(f, args.get(0).map(a => a.ty), env)
          if frame is Some(_) && order.is_empty() {
            raise @types.not_supported("window frame without ORDER BY")
          }
          mk_call(Agg(f, distinct=false), args, ty)
        }
      }
  }
}
