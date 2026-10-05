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
    out.push((v, r))
  }
  if !call.distinct || out.length() < 2 {
    return out
  }
  // DISTINCT: the first of each run of equal values, in input order
  // non-Unicode values compare as such (NUL below the space under SQL
  // sort orders; captured: msduck-runs character-extrema)
  let (ids, _) = group_ids(
    out.map(x => [x.0]),
    [coll],
    ansi=!arg.ty.is_unicode(),
  )
  let firsts : Array[(@types.Value, Row)] = []
  for i, x in out {
    if ids[i] == firsts.length() {
      firsts.push(x)
    }
  }
  firsts
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
        // captured: 1e308 + 1e308 is 8115 even when a later value would
        // cancel it (msduck float-aggregates #040-#044)
        if acc.is_inf() {
          raise @types.overflow_expression(Float)
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
  // SQL Server's one-pass formula (captured: msduck statistical-precision
  // and statistical-transition match it bit for bit, cancellation
  // included): (Σx² - (Σx)²/n) / (n - 1 | n) in float, a negative result
  // read as 0, an infinite sum 8115
  let mut sum = 0.0
  let mut squares = 0.0
  let mut n = 0
  for v in values {
    let x = match @types.cast(v.0, arg_ty, Float) {
      Float(f) => f
      _ => 0.0
    }
    sum = sum + x
    squares = squares + x * x
    if sum.is_inf() || squares.is_inf() {
      raise @types.overflow_expression(Float)
    }
    n += 1
  }
  if n == 0 || (n == 1 && !population) {
    return None
  }
  let nd = n.to_double()
  let v = (squares - sum * sum / nd) / (if population { nd } else { nd - 1.0 })
  Some(if v < 0.0 { 0.0 } else { v })
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
      let prev = ctx.rt.null_eliminated
      let vs = agg_inputs(ctx, call, rows)
      // an overflow stops the aggregation, so a NULL after it was never
      // seen: no 8153 (captured: SUM over (2147483647), (1), (NULL); an
      // overflow after a NULL is assumed to keep it, unverified)
      sum_values(vs, call.arg.unwrap().ty, call.ty) catch {
        @types.SqlError(number=8115, ..) as e => {
          ctx.rt.null_eliminated = prev
          raise e
        }
        e => raise e
      }
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
          let c = @types.compare(
            x.0,
            best,
            collation?=coll,
            ansi=!arg.ty.is_unicode(),
          ).unwrap_or(0)
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
      // non-LOB results are limited to 8000 bytes (captured: 9829 state 0,
      // analytic/string-agg-checks)
      let limit = match call.ty {
        VarChar(Some(_), _) => 8000
        NVarChar(Some(_), _) => 4000
        _ => -1
      }
      let mut len = 0
      for i, x in ordered {
        if i > 0 {
          buf.write_string(sep)
          len += sep.length()
        }
        match @types.cast(x.0, arg.ty, call.ty) {
          String(t) => {
            buf.write_string(t)
            len += t.length()
          }
          _ => ()
        }
        if limit >= 0 && len > limit {
          raise @types.sql_error(
            9829,
            "STRING_AGG aggregation result exceeded the limit of 8000 bytes. Use LOB types to avoid result truncation.",
            state=if limit == 8000 { 0 } else { 1 },
          )
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
    ChecksumAgg => checksum_agg(agg_inputs(ctx, call, rows))
    ApproxCountDistinct => approx_count_distinct(ctx, call, rows)
    JsonArrayAgg(..) | JsonObjectAgg(..) => eval_json_agg(ctx, call, rows)
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
  let ansi = keys.map(ansi_key)
  let prepared = keyed.map(kv => (order_keys(kv.0, keys, ansi), kv))
  sort_prepared(prepared, keys, ansi)
  prepared.map(p => p.1)
}

///|
/// ORDER BY sort keys of one row's key values.
fn order_keys(
  values : Array[@types.Value],
  keys : Array[@ir.SortKey],
  ansi : Array[Bool],
) -> Array[@types.SortKey] {
  values.mapi((i, v) => {
    @types.sort_key(v, collation?=keys[i].collation, ansi=ansi[i])
  })
}

///|
/// Sorts (order keys, item) pairs by ORDER BY `keys` in place.
fn[T] sort_prepared(
  prepared : Array[(Array[@types.SortKey], T)],
  keys : Array[@ir.SortKey],
  ansi : Array[Bool],
) -> Unit raise @types.SqlError {
  let mut failure : @types.SqlError? = None
  stable_sort_by(prepared, (a, b) => {
    for i, k in keys {
      let c = @types.compare_sort_keys(
        a.0[i],
        b.0[i],
        collation?=k.collation,
        ansi=ansi[i],
      ) catch {
        e => {
          failure = Some(e)
          0
        }
      }
      if c != 0 {
        return if k.desc { -c } else { c }
      }
    }
    0
  })
  if failure is Some(e) {
    raise e
  }
}

///|
fn compare_keys(
  a : Array[@types.Value],
  b : Array[@types.Value],
  keys : Array[@ir.SortKey],
) -> Int raise @types.SqlError {
  for i, k in keys {
    let c = compare_for_sort(a[i], b[i], k.collation, ansi=ansi_key(k))
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
    // groups in order of first appearance, each keeping its first key
    let cs = set.map(i => collations[i])
    let kvs = keyed.map(kr => set.map(i => kr.0[i]))
    let (ids, _) = group_ids(kvs, cs)
    let groups : Array[(Array[@types.Value], Array[Row])] = []
    for j, kr in keyed {
      if ids[j] == groups.length() {
        groups.push((kvs[j], [kr.1]))
      } else {
        groups[ids[j]].1.push(kr.1)
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
  if plain {
    return out
  }
  // grouping sets: key order with each subtotal after its detail rows
  // (captured ROLLUP order of a stream aggregate; CUBE / GROUPING SETS
  // orders are plan-dependent and unverified)
  let n = keys.length()
  let gid_at = n + aggs.length()
  let active = (r : Row, i : Int) => {
    match r[gid_at] {
      BigInt(g) => ((g >> (n - 1 - i)) & 1L) == 0L
      _ => true
    }
  }
  let mut failure : @types.SqlError? = None
  let sorted = out.copy()
  sorted.sort_by((a, b) => {
    for i in 0..<n {
      match (active(a, i), active(b, i)) {
        (true, false) => return -1
        (false, true) => return 1
        (false, false) => continue
        (true, true) => {
          let c = compare_for_sort(a[i], b[i], collations[i]) catch {
            e => {
              failure = Some(e)
              0
            }
          }
          if c != 0 {
            return c
          }
        }
      }
    }
    0
  })
  if failure is Some(e) {
    raise e
  }
  sorted
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
