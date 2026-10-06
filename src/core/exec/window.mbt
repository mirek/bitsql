///|
/// Window functions: each call partitions the input, orders each partition
/// and appends one value per row. The last eligible call decides output order.
fn run_window(
  ctx : Ctx,
  rows : Array[Row],
  calls : Array[@ir.WindowCall],
) -> Array[Row] raise @types.SqlError {
  let orders : Array[Array[Int]] = []
  let columns : Array[Array[@types.Value]] = []
  for call in calls {
    let (values, order) = window_values_ordered(ctx, rows, call)
    orders.push(order)
    columns.push(values)
  }
  // SQL Server's window operator emits rows sorted by the window's
  // PARTITION BY then ORDER BY keys (captured: msduck order-token #046,
  // SELECT a, ROW_NUMBER() OVER(ORDER BY a) without ORDER BY returns a in
  // order; order-token-expanded #032 ties keep that order). With several
  // window specifications the last one decides (unverified).
  let mut last : Int? = None
  for i, call in calls {
    if !(call.func is (PercentileCont | PercentileDisc)) &&
      (!call.partition.is_empty() || !call.order.is_empty()) {
      last = Some(i)
    }
  }
  let make_row = (i : Int) => {
    let r = rows[i]
    let row = Array(capacity=r.length() + columns.length())
    for v in r {
      row.push(v)
    }
    for c in columns {
      row.push(c[i])
    }
    row
  }
  match last {
    // the call's own partition-then-order sort (window_values_ordered)
    Some(i) => orders[i].map(make_row)
    None => Array::makei(rows.length(), make_row)
  }
}

///|
/// Whether two key rows agree on their first `n` columns (`same_row`).
fn same_prefix(
  a : Array[@types.Value],
  b : Array[@types.Value],
  n : Int,
  collations : Array[@types.Collation?],
) -> Bool raise @types.SqlError {
  for i in 0..<n {
    match (a[i], b[i]) {
      (Null, Null) => continue
      (Null, _) | (_, Null) => return false
      (x, y) =>
        if @types.compare(x, y, collation?=collations[i]) != Some(0) {
          return false
        }
    }
  }
  true
}

///|
fn window_values(
  ctx : Ctx,
  rows : Array[Row],
  call : @ir.WindowCall,
) -> Array[@types.Value] raise @types.SqlError {
  window_values_ordered(ctx, rows, call).0
}

///|
/// Window values in input order, plus the input positions sorted by the
/// call's PARTITION BY then ORDER BY keys (stable): run_window's output
/// order when this call decides it.
fn window_values_ordered(
  ctx : Ctx,
  rows : Array[Row],
  call : @ir.WindowCall,
) -> (Array[@types.Value], Array[Int]) raise @types.SqlError {
  let result = Array::make(rows.length(), @types.Value::Null)
  // the percentile is evaluated once per call, also for no rows (captured:
  // RAND() in it advances the generator once, msduck
  // percentile-runtime-fraction rand-advancement)
  let fraction = if call.func is (PercentileCont | PercentileDisc) {
    eval(ctx, call.args[0])
  } else {
    Null
  }
  // one stable sort by PARTITION BY ++ ORDER BY keys: partitions are runs
  // of equal partition keys (same equality as same_row: collation-aware,
  // NULLs equal), each ordered by the ORDER BY keys with ties in input
  // order; O(n log n)
  let np = call.partition.length()
  let all_keys : Array[@ir.SortKey] = call.partition.mapi((i, p) => @ir.SortKey::{
    expr: p,
    desc: false,
    collation: call.partition_collations[i],
  })
  for k in call.order {
    all_keys.push(k)
  }
  let cs = all_keys.map(k => compile(k.expr))
  if call.func is RowNumber && all_keys[0:np].iter().all(k => !ansi_key(k)) {
    // Direct column reads are pure: normalize the input rows without
    // materializing another array of key values for every row.
    let columns = window_key_columns(all_keys)
    if columns is Some(_) {
      if row_numbers_normalized(rows, all_keys, np, result, columns~)
        is Some(order) {
        return (result, order)
      }
    }
    let values = rows.map(r => cs.map(f => f(ctx, r)))
    if columns is None {
      if row_numbers_normalized(values, all_keys, np, result) is Some(order) {
        return (result, order)
      }
    }
    // Encoding failed; use the general comparator without trying it again.
    let sorted = sort_keyed_general(values.mapi((i, v) => (v, i)), all_keys)
    row_numbers(sorted, np, call.partition_collations, result)
    return (result, sorted.map(kv => kv.1))
  }
  let keyed = rows.mapi((i, r) => (cs.map(f => f(ctx, r)), i))
  let sorted_all = sort_keyed(keyed, all_keys)
  if call.func is RowNumber {
    row_numbers(sorted_all, np, call.partition_collations, result)
    return (result, sorted_all.map(kv => kv.1))
  }
  let parts : Array[(Int, Int)] = []
  let mut start = 0
  for j in 1..<=sorted_all.length() {
    if j == sorted_all.length() ||
      !same_prefix(
        sorted_all[j - 1].0,
        sorted_all[j].0,
        np,
        call.partition_collations,
      ) {
      if j > start {
        parts.push((start, j))
      }
      start = j
    }
  }
  for p in parts {
    let sorted = sorted_all[p.0:p.1]
    let idx = sorted.iter().map(kv => kv.1).to_array()
    let keys = sorted.iter().map(kv => kv.0[np:].to_owned()).to_array()
    let n = idx.length()
    // peer group boundaries [start, end) per position
    let peer_start = Array::make(n, 0)
    let peer_end = Array::make(n, n)
    let mut s = 0
    for j in 1..<=n {
      if j == n || compare_keys(keys[j - 1], keys[j], call.order) != 0 {
        for k in s..<j {
          peer_start[k] = s
          peer_end[k] = j
        }
        s = j
      }
    }
    let part_rows = idx.map(i => rows[i])
    if call.func is (PercentileCont | PercentileDisc) {
      let v = percentile_value(call, fraction, keys)
      for i in idx {
        result[i] = v
      }
      continue
    }
    // running COUNT/SUM over frames growing from the partition start:
    // one pass instead of re-aggregating every frame (quadratic)
    let running = running_aggregate(ctx, call, part_rows, peer_start, peer_end)
    let mut dense = 0
    for j in 0..<n {
      if peer_start[j] == j {
        dense += 1
      }
      let row_ctx = if call.func
        is (RowNumber | Rank | DenseRank | PercentRank | CumeDist) {
        ctx
      } else {
        ctx.with_row(part_rows[j])
      }
      let v : @types.Value = match call.func {
        RowNumber => BigInt((j + 1).to_int64())
        Rank => BigInt((peer_start[j] + 1).to_int64())
        DenseRank => BigInt(dense.to_int64())
        PercentRank =>
          Float(
            if n <= 1 {
              0.0
            } else {
              peer_start[j].to_double() / (n - 1).to_double()
            },
          )
        CumeDist => Float(peer_end[j].to_double() / n.to_double())
        PercentileCont | PercentileDisc => Null
        NextValue => {
          // one sequence value per row in OVER (ORDER BY) order (captured:
          // tail5/b1-next-value-over)
          ctx.rt.next_row()
          eval(row_ctx, call.args[0])
        }
        Ntile => {
          // captured: a NULL or non-positive count at run time is 4116
          // (severity 15); counts beyond the row count give one row each
          let buckets = match eval(row_ctx, call.args[0]).as_int64() {
            Some(b) if b > 0L =>
              if b > 2147483647L {
                2147483647
              } else {
                b.to_int()
              }
            _ =>
              raise @types.sql_error(
                4116,
                "The function 'ntile' takes only a positive int or bigint expression as its input.",
                severity=15,
              )
          }
          let size = n / buckets
          let extra = n % buckets
          // the first `extra` buckets hold size + 1 rows
          let big = extra * (size + 1)
          let b = if j < big {
            j / (size + 1)
          } else if size == 0 {
            extra
          } else {
            extra + (j - big) / size
          }
          BigInt((b + 1).to_int64())
        }
        Lag | Lead => {
          // captured: a NULL offset gives NULL, a negative one is 8730
          // (functions2/offset-window)
          let off = if call.args.length() > 1 {
            match eval(row_ctx, call.args[1]) {
              Null => -1
              o =>
                match o.as_int64() {
                  Some(o) if o >= 0L => o.to_int()
                  _ =>
                    raise @types.sql_error(
                      8730, "Offset parameter for Lag and Lead functions cannot be a negative value.",
                    )
                }
            }
          } else {
            1
          }
          let step = if call.func is Lag { -1 } else { 1 }
          let target = j + step * off
          if off < 0 {
            Null
          } else if target >= 0 && target < n {
            let value = eval(ctx.with_row(part_rows[target]), call.args[0])
            // IGNORE NULLS: from the offset row, keep moving away from the
            // current row to the first non-NULL value; none is NULL, not
            // the default (captured: LAG(x, 2, -1) IGNORE NULLS)
            if call.ignore_nulls && value is Null {
              let mut k = target + step
              let mut found : @types.Value = Null
              while k >= 0 && k < n {
                let w = eval(ctx.with_row(part_rows[k]), call.args[0])
                if !(w is Null) {
                  found = w
                  break
                }
                k += step
              }
              found
            } else {
              value
            }
          } else if call.args.length() > 2 {
            eval(row_ctx, call.args[2])
          } else {
            Null
          }
        }
        FirstValue | LastValue | Agg(_, ..) => {
          let (fs, fe) = frame_bounds(row_ctx, call, j, n, peer_start, peer_end)
          match call.func {
            // IGNORE NULLS: the first (last) non-NULL value of the frame
            FirstValue => {
              let mut r : @types.Value = Null
              for k in fs..<fe {
                r = eval(ctx.with_row(part_rows[k]), call.args[0])
                if !call.ignore_nulls || !(r is Null) {
                  break
                }
              }
              r
            }
            LastValue => {
              let mut r : @types.Value = Null
              let mut k = fe - 1
              while k >= fs {
                r = eval(ctx.with_row(part_rows[k]), call.args[0])
                if !call.ignore_nulls || !(r is Null) {
                  break
                }
                k -= 1
              }
              r
            }
            Agg(_, ..) if running is Some(r) => r[j]
            Agg(f, distinct~) => {
              let agg : @ir.AggCall = {
                func: f,
                arg: call.args.get(0),
                // JSON_OBJECTAGG's key
                separator: call.args.get(1),
                distinct,
                order: [],
                ty: call.ty,
              }
              if fs < fe {
                eval_aggregate(ctx, agg, part_rows[fs:fe])
              } else {
                eval_aggregate(ctx, agg, part_rows[0:0])
              }
            }
            _ => Null
          }
        }
      }
      result[idx[j]] = v
    }
  }
  (result, sorted_all.map(kv => kv.1))
}

///|
/// Frame of position j as [start, end) within a partition of n rows.
fn frame_bounds(
  ctx : Ctx,
  call : @ir.WindowCall,
  j : Int,
  n : Int,
  peer_start : Array[Int],
  peer_end : Array[Int],
) -> (Int, Int) raise @types.SqlError {
  let offset = (e : @ir.Expr) => {
    match eval(ctx, e).as_int64() {
      Some(o) if o >= 0L => o.to_int()
      _ => raise @types.not_supported("negative or NULL window frame offsets")
    }
  }
  match call.frame {
    None => if call.order.is_empty() { (0, n) } else { (0, peer_end[j]) }
    Some(f) => {
      let start = match f.start {
        UnboundedPreceding => 0
        CurrentRow => if f.rows { j } else { peer_start[j] }
        Preceding(e) => j - offset(e)
        Following(e) => j + offset(e)
        UnboundedFollowing => n
      }
      let end = match f.end {
        UnboundedFollowing => n
        CurrentRow => if f.rows { j + 1 } else { peer_end[j] }
        Following(e) => j + offset(e) + 1
        Preceding(e) => j - offset(e) + 1
        UnboundedPreceding => 0
      }
      let clamp = (x : Int) => if x < 0 { 0 } else if x > n { n } else { x }
      (clamp(start), clamp(end))
    }
  }
}

///|
/// Prefix results of COUNT / COUNT_BIG / SUM when every frame of the
/// partition starts at its first row and frame ends never move back (the
/// default RANGE frame with ORDER BY, ROWS UNBOUNDED PRECEDING). Values,
/// overflow checks and the 8153 flag match `eval_aggregate` on each frame:
/// SUM checks every partial sum, so a prefix fails exactly when it would.
/// None: not this shape; evaluate frame by frame.
fn running_aggregate(
  ctx : Ctx,
  call : @ir.WindowCall,
  part_rows : Array[Row],
  peer_start : Array[Int],
  peer_end : Array[Int],
) -> Array[@types.Value]? raise @types.SqlError {
  guard call.func is Agg(f, distinct=false) && f is (Count | CountBig | Sum) else {
    return None
  }
  let n = part_rows.length()
  let ends = []
  let mut last = 0
  for j in 0..<n {
    let (fs, fe) = frame_bounds(
      ctx.with_row(part_rows[j]),
      call,
      j,
      n,
      peer_start,
      peer_end,
    )
    if fs != 0 || fe < last {
      return None
    }
    ends.push(fe)
    last = fe
  }
  let arg = call.args.get(0)
  let ty = call.ty
  let arg_ty = match arg {
    Some(a) => a.ty
    None => ty
  }
  if f is Sum &&
    !(ty
    is (TinyInt
    | SmallInt
    | Int
    | BigInt
    | Decimal(_, _)
    | Numeric(_, _)
    | Money
    | SmallMoney
    | Float
    | Real)) {
    return None
  }
  let out = []
  let mut k = 0
  let mut count = 0
  let mut iacc = 0L
  let mut facc = 0.0
  let mut dacc = match ty {
    Decimal(_, s) | Numeric(_, s) => @types.Decimal::zero().rescale(s)
    _ => @types.Decimal::zero()
  }
  for j in 0..<n {
    while k < ends[j] {
      let v : @types.Value = match arg {
        Some(a) => eval(ctx.with_row(part_rows[k]), a)
        None => Int(1)
      }
      k += 1
      if v is Null {
        ctx.rt.null_eliminated = true
        continue
      }
      count += 1
      if f is Sum {
        match ty {
          TinyInt | SmallInt | Int | BigInt => {
            let (lo, hi) = @types.int_range(ty)
            let x = v.as_int64().unwrap_or(0L)
            let s = iacc + x
            if (x > 0L && s < iacc) || (x < 0L && s > iacc) || s < lo || s > hi {
              raise @types.overflow_expression(ty)
            }
            iacc = s
          }
          Decimal(p, s) | Numeric(p, s) => {
            dacc = dacc.add(@types.cast(v, arg_ty, ty).as_decimal().unwrap())
            if !dacc.fits(p, s) {
              raise @types.overflow_expression(ty)
            }
          }
          Money | SmallMoney => {
            let x = match @types.cast(v, arg_ty, Money) {
              Money(m) => m
              _ => 0L
            }
            let s = iacc + x
            if (x > 0L && s < iacc) || (x < 0L && s > iacc) {
              raise @types.overflow_expression(ty)
            }
            iacc = s
          }
          _ => {
            match @types.cast(v, arg_ty, Float) {
              Float(x) => facc = facc + x
              _ => ()
            }
            if facc.is_inf() {
              raise @types.overflow_expression(Float)
            }
          }
        }
      }
    }
    out.push(
      match f {
        Count => @types.Value::Int(count)
        CountBig => BigInt(count.to_int64())
        _ =>
          if count == 0 {
            Null
          } else {
            match ty {
              TinyInt | SmallInt | Int | BigInt => @types.int_value(ty, iacc)
              Decimal(_, s) | Numeric(_, s) => Decimal(dacc.rescale(s))
              Money | SmallMoney => Money(iacc)
              _ => Float(facc)
            }
          }
      },
    )
  }
  Some(out)
}

///|
/// A window operator whose output order is decided by its only NEXT VALUE
/// FOR … OVER call streams rows as their values are drawn: rows numbered
/// before an exhausted sequence's 11728 are sent before the error
/// (captured: tail5/b1-next-value-over).
fn next_value_streams(calls : Array[@ir.WindowCall]) -> Bool {
  let nv = calls.filter(c => c.func is NextValue)
  if nv.length() != 1 {
    return false
  }
  // the last call with keys decides the output order (run_window)
  let mut last = -1
  for i, c in calls {
    if !(c.func is (PercentileCont | PercentileDisc)) &&
      (!c.partition.is_empty() || !c.order.is_empty()) {
      last = i
    }
  }
  last >= 0 && calls[last].func is NextValue
}

///|
fn stream_next_value_window(
  ctx : Ctx,
  rows : Array[Row],
  calls : Array[@ir.WindowCall],
  emit : (Row) -> Unit raise @types.SqlError,
) -> Unit raise @types.SqlError {
  // the other calls first, as run_window computes them
  let values : Array[Array[@types.Value]] = calls.map(c => {
    if c.func is NextValue {
      []
    } else {
      window_values(ctx, rows, c)
    }
  })
  let at = calls.search_by(c => c.func is NextValue).unwrap_or(0)
  let call = calls[at]
  let keyed = rows.mapi((i, r) => {
    (call.order.map(k => eval(ctx.with_row(r), k.expr)), i)
  })
  for kv in sort_keyed(keyed, call.order) {
    let i = kv.1
    ctx.rt.next_row()
    let v = eval(ctx.with_row(rows[i]), call.args[0])
    let out = rows[i].copy()
    for j, vs in values {
      out.push(if j == at { v } else { vs[i] })
    }
    emit(out)
  }
}

///|
/// Keep the same adjacent partition comparisons as the general window path.
/// Rank writes are local and cannot raise; no partial values escape on error.
fn row_numbers(
  sorted : Array[(Array[@types.Value], Int)],
  np : Int,
  collations : Array[@types.Collation?],
  result : Array[@types.Value],
) -> Unit raise @types.SqlError {
  let mut start = 0
  for j, kv in sorted {
    if j > 0 && !same_prefix(sorted[j - 1].0, kv.0, np, collations) {
      start = j
    }
    result[kv.1] = BigInt((j - start + 1).to_int64())
  }
}

///|
/// Reuse exact normalized partition prefixes while retaining the full stable
/// sort. Partition equality uses ansi=false, so ANSI partition keys retain
/// the original path. None leaves result untouched and values reusable.
fn row_numbers_normalized(
  values : Array[Array[@types.Value]],
  keys : Array[@ir.SortKey],
  np : Int,
  result : Array[@types.Value],
  columns? : Array[Int]? = None,
) -> Array[Int]? {
  for i in 0..<np {
    if ansi_key(keys[i]) {
      return None
    }
  }
  let ends : Array[Int] = []
  guard normalized_keys(values, keys, prefix=Some((np, ends)), columns~)
    is Some(ks) else {
    return None
  }
  let order = Array::makei(values.length(), i => i)
  let prefix = normalized_common_prefix(ks)
  stable_sort_by(order, (i, j) => compare_normalized(ks[i], ks[j], start=prefix))
  let mut start = 0
  for j, at in order {
    if j > 0 {
      let prev = order[j - 1]
      let mut same = ends[prev] == ends[at]
      if same {
        for k in 0..<ends[at] {
          if ks[prev][k] != ks[at][k] {
            same = false
            break
          }
        }
      }
      if !same {
        start = j
      }
    }
    result[at] = BigInt((j - start + 1).to_int64())
  }
  Some(order)
}

///|
fn window_key_columns(keys : Array[@ir.SortKey]) -> Array[Int]? {
  let columns = []
  for key in keys {
    match key.expr.kind {
      Col(i) => columns.push(i)
      _ => return None
    }
  }
  Some(columns)
}
