///|
/// Aggregate evaluation over a group of rows (GROUP BY and window frames).
/// Result types come from the binder (bind/aggregate.mbt); accumulation
/// follows them: SUM/AVG accumulate in the result type with overflow
/// checks (8115), AVG truncates its quotient.

///|
/// Values of an aggregate's argument over `rows`, NULLs removed (setting
/// the 8153 flag), DISTINCT applied.
fn agg_inputs(
  ctx : Ctx,
  call : @ir.AggCall,
  rows : ArrayView[Row],
) -> Array[(@types.Value, Row)] raise @types.SqlError {
  guard call.arg is Some(arg) else {
    return rows.iter().map(r => (@types.Value::Null, r)).to_array()
  }
  let out : Array[(@types.Value, Row)] = []
  let coll = arg.ty.collation()
  for r in rows {
    let v = eval(ctx.with_row(r), arg)
    if v is Null {
      // captured: STRING_AGG skips NULLs without warning 8153
      if !(call.func is StringAgg) {
        ctx.rt.null_eliminated = true
      }
      continue
    }
    if call.distinct {
      let mut dup = false
      for seen in out {
        if @types.compare(seen.0, v, collation?=coll) == Some(0) {
          dup = true
          break
        }
      }
      if dup {
        continue
      }
    }
    out.push((v, r))
  }
  out
}

///|
fn sum_values(
  values : Array[(@types.Value, Row)],
  arg_ty : @types.SqlType,
  ty : @types.SqlType,
) -> @types.Value raise @types.SqlError {
  if values.is_empty() {
    return Null
  }
  match ty {
    TinyInt | SmallInt | Int | BigInt => {
      let (lo, hi) = @types.int_range(ty)
      let mut acc = 0L
      for x in values {
        let v = x.0.as_int64().unwrap_or(0L)
        let s = acc + v
        // overflow of Int64 itself or of the result type
        if (v > 0L && s < acc) || (v < 0L && s > acc) || s < lo || s > hi {
          raise @types.overflow_expression(ty)
        }
        acc = s
      }
      @types.int_value(ty, acc)
    }
    Decimal(p, s) | Numeric(p, s) => {
      let mut acc = @types.Decimal::zero().rescale(s)
      for x in values {
        let d = @types.cast(x.0, arg_ty, ty).as_decimal().unwrap()
        acc = acc.add(d)
        if !acc.fits(p, s) {
          raise @types.overflow_expression(ty)
        }
      }
      Decimal(acc.rescale(s))
    }
    Money | SmallMoney => {
      let mut acc = 0L
      for x in values {
        let v = match @types.cast(x.0, arg_ty, Money) {
          Money(m) => m
          _ => 0L
        }
        let s = acc + v
        if (v > 0L && s < acc) || (v < 0L && s > acc) {
          raise @types.overflow_expression(ty)
        }
        acc = s
      }
      Money(acc)
    }
    Float | Real => {
      let mut acc = 0.0
      for x in values {
        match @types.cast(x.0, arg_ty, Float) {
          Float(f) => acc = acc + f
          _ => ()
        }
      }
      Float(acc)
    }
    _ => raise @types.not_supported("SUM of \{ty.to_sql()}")
  }
}

///|
fn avg_values(
  values : Array[(@types.Value, Row)],
  arg_ty : @types.SqlType,
  ty : @types.SqlType,
) -> @types.Value raise @types.SqlError {
  if values.is_empty() {
    return Null
  }
  let n = values.length().to_int64()
  match ty {
    TinyInt | SmallInt | Int | BigInt =>
      match sum_values(values, arg_ty, ty).as_int64() {
        Some(s) => @types.int_value(ty, s / n)
        None => Null
      }
    Decimal(p, s) | Numeric(p, s) => {
      // sum in decimal(38, input scale), quotient truncated at the result scale
      let in_scale = match arg_ty {
        Decimal(_, x) | Numeric(_, x) => x
        _ => 0
      }
      let sum_ty : @types.SqlType = Decimal(38, in_scale)
      let total = match sum_values(values, arg_ty, sum_ty) {
        Decimal(d) => d
        _ => @types.Decimal::zero()
      }
      let q = total.div(@types.Decimal::from_int64(n), s)
      if !q.fits(p, s) {
        raise @types.overflow_expression(ty)
      }
      Decimal(q)
    }
    Money | SmallMoney =>
      match sum_values(values, arg_ty, Money) {
        Money(m) => Money(m / n)
        _ => Null
      }
    Float | Real =>
      match sum_values(values, arg_ty, Float) {
        Float(f) => Float(f / n.to_double())
        _ => Null
      }
    _ => raise @types.not_supported("AVG of \{ty.to_sql()}")
  }
}

///|
fn variance(
  values : Array[(@types.Value, Row)],
  arg_ty : @types.SqlType,
  population : Bool,
) -> Double? raise @types.SqlError {
  let xs = values.map(x => {
    match @types.cast(x.0, arg_ty, Float) {
      Float(f) => f
      _ => 0.0
    }
  })
  let n = xs.length()
  if n == 0 || (n == 1 && !population) {
    return None
  }
  let mut mean = 0.0
  for x in xs {
    mean = mean + x
  }
  mean = mean / n.to_double()
  let mut ss = 0.0
  for x in xs {
    ss = ss + (x - mean) * (x - mean)
  }
  Some(ss / (if population { n } else { n - 1 }).to_double())
}

///|
/// Evaluates one aggregate over a group of rows.
pub fn eval_aggregate(
  ctx : Ctx,
  call : @ir.AggCall,
  rows : ArrayView[Row],
) -> @types.Value raise @types.SqlError {
  match call.func {
    Count | CountBig => {
      let n = match call.arg {
        None => rows.length()
        Some(_) => agg_inputs(ctx, call, rows).length()
      }
      if call.func is Count {
        Int(n)
      } else {
        BigInt(n.to_int64())
      }
    }
    Sum => {
      let vs = agg_inputs(ctx, call, rows)
      sum_values(vs, call.arg.unwrap().ty, call.ty)
    }
    Avg => {
      let vs = agg_inputs(ctx, call, rows)
      avg_values(vs, call.arg.unwrap().ty, call.ty)
    }
    Min | Max => {
      let arg = call.arg.unwrap()
      let coll = arg.ty.collation()
      let mut best : @types.Value = Null
      for x in agg_inputs(ctx, call, rows) {
        if best is Null {
          best = x.0
        } else {
          let c = @types.compare(x.0, best, collation?=coll).unwrap_or(0)
          if (call.func is Min && c < 0) || (call.func is Max && c > 0) {
            best = x.0
          }
        }
      }
      if best is Null {
        Null
      } else {
        @types.cast(best, arg.ty, call.ty)
      }
    }
    StringAgg => {
      let arg = call.arg.unwrap()
      let vs = agg_inputs(ctx, call, rows)
      if vs.is_empty() {
        return Null
      }
      let ordered = if call.order.is_empty() {
        vs
      } else {
        sort_rows_by(ctx, vs, x => x.1, call.order)
      }
      let sep = match call.separator {
        Some(s) =>
          match @types.cast(eval(ctx, s), s.ty, call.ty) {
            String(t) => t
            _ => ""
          }
        None => ""
      }
      let buf = StringBuilder()
      for i, x in ordered {
        if i > 0 {
          buf.write_string(sep)
        }
        match @types.cast(x.0, arg.ty, call.ty) {
          String(t) => buf.write_string(t)
          _ => ()
        }
      }
      String(buf.to_string())
    }
    Stdev | StdevP | Var | VarP => {
      let vs = agg_inputs(ctx, call, rows)
      let population = call.func is (StdevP | VarP)
      match variance(vs, call.arg.unwrap().ty, population) {
        None => Null
        Some(v) =>
          if call.func is (Stdev | StdevP) {
            Float(v.sqrt())
          } else {
            Float(v)
          }
      }
    }
    // computed by the Aggregate plan from the grouping set
    Grouping(_) | GroupingId(_) => Null
  }
}

///|
/// Stable sort of items by ORDER BY keys evaluated on each item's row.
fn[T] sort_rows_by(
  ctx : Ctx,
  items : Array[T],
  row_of : (T) -> Row,
  keys : Array[@ir.SortKey],
) -> Array[T] raise @types.SqlError {
  let keyed = items.map(x => {
    (keys.map(k => eval(ctx.with_row(row_of(x)), k.expr)), x)
  })
  sort_keyed(keyed, keys).map(kv => kv.1)
}

///|
fn[T] sort_keyed(
  keyed : Array[(Array[@types.Value], T)],
  keys : Array[@ir.SortKey],
) -> Array[(Array[@types.Value], T)] raise @types.SqlError {
  let mut failure : @types.SqlError? = None
  let out = keyed.copy()
  out.sort_by((a, b) => {
    compare_keys(a.0, b.0, keys) catch {
      e => {
        failure = Some(e)
        0
      }
    }
  })
  if failure is Some(e) {
    raise e
  }
  out
}

///|
fn compare_keys(
  a : Array[@types.Value],
  b : Array[@types.Value],
  keys : Array[@ir.SortKey],
) -> Int raise @types.SqlError {
  for i, k in keys {
    let c = compare_for_sort(a[i], b[i], k.collation)
    if c != 0 {
      return if k.desc { -c } else { c }
    }
  }
  0
}

///|
/// GROUP BY: groups rows by key values (NULLs group together), in order of
/// first appearance, for every grouping set.
fn run_aggregate(
  ctx : Ctx,
  rows : Array[Row],
  keys : Array[@ir.Expr],
  aggs : Array[@ir.AggCall],
  sets : Array[Array[Int]],
) -> Array[Row] raise @types.SqlError {
  let collations = keys.map(k => k.ty.collation())
  let keyed = rows.map(r => (keys.map(k => eval(ctx.with_row(r), k)), r))
  let plain = sets.is_empty()
  let all_keys = Array::makei(keys.length(), i => i)
  let out : Array[Row] = []
  for set in (if plain { [all_keys] } else { sets }) {
    // group id bit i set when key i is NOT in this set (GROUPING_ID order)
    let mut gid = 0L
    for i in 0..<keys.length() {
      gid = gid * 2L + (if set.contains(i) { 0L } else { 1L })
    }
    let groups : Array[(Array[@types.Value], Array[Row])] = []
    for kr in keyed {
      let kv = set.map(i => kr.0[i])
      let cs = set.map(i => collations[i])
      let mut found = -1
      for gi, g in groups {
        if same_row(g.0, kv, cs) {
          found = gi
          break
        }
      }
      if found >= 0 {
        groups[found].1.push(kr.1)
      } else {
        groups.push((kv, [kr.1]))
      }
    }
    // scalar aggregate (no GROUP BY): one row even over empty input;
    // captured: GROUP BY () and ROLLUP return no rows for empty input
    if groups.is_empty() && plain && keys.is_empty() {
      groups.push(([], []))
    }
    for g in groups {
      let row : Row = Array::make(keys.length(), @types.Value::Null)
      for j, i in set {
        row[i] = g.0[j]
      }
      for a in aggs {
        let v = match a.func {
          Grouping(i) =>
            @types.Value::TinyInt(if set.contains(i) { 0 } else { 1 })
          GroupingId(ks) => {
            let mut id = 0
            for i in ks {
              id = id * 2 + (if set.contains(i) { 0 } else { 1 })
            }
            Int(id)
          }
          _ => eval_aggregate(ctx, a, g.1[:])
        }
        row.push(v)
      }
      if !plain {
        row.push(BigInt(gid))
      }
      out.push(row)
    }
  }
  out
}

///|
/// Equal-under-collation string values (CI 'a' / 'A') show one spelling.
/// SQL Server's choice is plan-dependent. Captures of DISTINCT, UNION and
/// EXCEPT show the binary-smallest spelling ('A'), so set operations use
/// that; GROUP BY keeps the first spelling seen (traps/collation-ci-trailing-
/// spaces, VALUES probes), although some heap-table plans differ.
fn prefer_representative(
  kept : Array[@types.Value],
  other : Array[@types.Value],
) -> Unit {
  for i in 0..<kept.length() {
    match (kept[i], other[i]) {
      (String(a), String(b)) if code_unit_less(b, a) => kept[i] = other[i]
      _ => ()
    }
  }
}

///|
fn code_unit_less(a : String, b : String) -> Bool {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a.code_unit_at(i)
    let y = b.code_unit_at(i)
    if x != y {
      return x < y
    }
  }
  a.length() < b.length()
}
