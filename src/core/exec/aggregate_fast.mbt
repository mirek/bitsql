// Accumulator-based GROUP BY for the common aggregates: one pass over the
// input updating per-group state, instead of collecting every group's rows
// and argument values and reducing them afterwards (`run_aggregate`). Same
// grouping (`group_ids`), same per-value rules as `sum_values`/`avg_values`
// and the MIN/MAX arm of `eval_aggregate`; arguments are evaluated row by
// row in input order, as SQL Server's stream and hash aggregates consume
// them (a SUM overflow stops before later rows, so a NULL after it is never
// seen: no 8153, captured). docs/design/performance.md.

///|
/// Whether every call is one `run_aggregate_fast` implements.
fn fast_aggregates(aggs : Array[@ir.AggCall]) -> Bool {
  aggs
  .iter()
  .all(a => {
    !a.distinct &&
    a.separator is None &&
    a.order.is_empty() &&
    (match a.func {
      Count | CountBig | Min | Max => true
      Sum | Avg => a.ty is (TinyInt | SmallInt | Int | BigInt | Float | Real)
      _ => false
    })
  })
}

///|
priv struct AggState {
  count : Array[Int64]
  sum : Array[Int64]
  fsum : Array[Double]
  best : Array[@types.Value]
}

///|
fn run_aggregate_fast(
  ctx : Ctx,
  rows : Array[Row],
  keys : Array[@ir.Expr],
  aggs : Array[@ir.AggCall],
) -> Array[Row] raise @types.SqlError {
  let n = rows.length()
  // group of each row and the key values of each group (first row's)
  let (ids, firsts) = if keys.is_empty() {
    // scalar aggregate: one group, even over empty input
    (Array::make(n, 0), [[]])
  } else {
    let cs = keys.map(compile)
    let kvs = rows.map(r => cs.map(f => f(ctx, r)))
    let (ids, _) = group_ids(kvs, keys.map(k => k.ty.collation()))
    // ids number groups in order of first appearance
    let firsts : Array[Row] = []
    for j, id in ids {
      if id == firsts.length() {
        firsts.push(kvs[j])
      }
    }
    (ids, firsts)
  }
  let groups = firsts.length()
  let args = aggs.map(a => a.arg.map(compile))
  let states = new_states(aggs, groups)
  for j, row in rows {
    accumulate(ctx, aggs, args, states, ids[j], row)
  }
  firsts.mapi((g, key) => finish_group(aggs, states, g, key))
}

///|
fn new_states(aggs : Array[@ir.AggCall], groups : Int) -> Array[AggState] {
  aggs.map(_ => {
    count: Array::make(groups, 0L),
    sum: Array::make(groups, 0L),
    fsum: Array::make(groups, 0.0),
    best: Array::make(groups, @types.Value::Null),
  })
}

///|
/// Folds one input row into group `g` of every call's state.
fn accumulate(
  ctx : Ctx,
  aggs : Array[@ir.AggCall],
  args : Array[Compiled?],
  states : Array[AggState],
  g : Int,
  row : Row,
) -> Unit raise @types.SqlError {
  for i, a in aggs {
    let st = states[i]
    guard args[i] is Some(arg) else {
      st.count[g] = st.count[g] + 1L
      continue
    }
    let v = arg(ctx, row)
    if v is Null {
      ctx.rt.null_eliminated = true
      continue
    }
    st.count[g] = st.count[g] + 1L
    match a.func {
      Sum | Avg =>
        if a.ty is (Float | Real) {
          let f = match @types.cast(v, a.arg.unwrap().ty, Float) {
            Float(f) => f
            _ => 0.0
          }
          let acc = st.fsum[g] + f
          // captured: 1e308 + 1e308 is 8115 even when a later value
          // would cancel it (msduck float-aggregates #040-#044)
          if acc.is_inf() {
            raise @types.overflow_expression(Float)
          }
          st.fsum[g] = acc
        } else {
          let (lo, hi) = @types.int_range(a.ty)
          let acc = st.sum[g]
          let x = v.int64_or(0L)
          let s = acc + x
          // overflow of Int64 itself or of the result type
          if (x > 0L && s < acc) || (x < 0L && s > acc) || s < lo || s > hi {
            raise @types.overflow_expression(a.ty)
          }
          st.sum[g] = s
        }
      Min | Max => {
        let best = st.best[g]
        if best is Null {
          st.best[g] = v
        } else {
          let arg_ty = a.arg.unwrap().ty
          let c = @types.compare(
            v,
            best,
            collation?=arg_ty.collation(),
            ansi=!arg_ty.is_unicode(),
          ).unwrap_or(0)
          if (a.func is Min && c < 0) || (a.func is Max && c > 0) {
            st.best[g] = v
          }
        }
      }
      _ => ()
    }
  }
}

///|
/// The output row of group `g`: its key values, then each call's value.
fn finish_group(
  aggs : Array[@ir.AggCall],
  states : Array[AggState],
  g : Int,
  key : Row,
) -> Row raise @types.SqlError {
  let row : Row = key.copy()
  for i, a in aggs {
    let st = states[i]
    let n = st.count[g]
    row.push(
      match a.func {
        Count => Int(n.to_int())
        CountBig => BigInt(n)
        Sum if n == 0L => Null
        Sum =>
          if a.ty is (Float | Real) {
            Float(st.fsum[g])
          } else {
            @types.int_value(a.ty, st.sum[g])
          }
        Avg if n == 0L => Null
        Avg =>
          if a.ty is (Float | Real) {
            Float(st.fsum[g] / n.to_double())
          } else {
            @types.int_value(a.ty, st.sum[g] / n)
          }
        Min | Max =>
          match st.best[g] {
            Null => Null
            b => @types.cast(b, a.arg.unwrap().ty, a.ty)
          }
        _ => Null
      },
    )
  }
  row
}

///|
/// A scalar aggregate (no GROUP BY) of `fast_aggregates` calls, folding the
/// input rows as the input streams them (no materialized input).
fn stream_aggregate(
  ctx : Ctx,
  input : @ir.Plan,
  aggs : Array[@ir.AggCall],
) -> Array[Row] raise @types.SqlError {
  let args = aggs.map(a => a.arg.map(compile))
  let states = new_states(aggs, 1)
  stream(ctx, input, row => accumulate(ctx, aggs, args, states, 0, row))
  [finish_group(aggs, states, 0, [])]
}
