///|
/// Window functions: each call partitions the input, orders each partition
/// and appends one value per row. Output keeps the input row order.
fn run_window(
  ctx : Ctx,
  rows : Array[Row],
  calls : Array[@ir.WindowCall],
) -> Array[Row] raise @types.SqlError {
  let out = rows.map(r => r.copy())
  for call in calls {
    let values = window_values(ctx, rows, call)
    for i, v in values {
      out[i].push(v)
    }
  }
  out
}

///|
fn window_values(
  ctx : Ctx,
  rows : Array[Row],
  call : @ir.WindowCall,
) -> Array[@types.Value] raise @types.SqlError {
  let result = Array::make(rows.length(), @types.Value::Null)
  // the percentile is evaluated once per call, also for no rows (captured:
  // RAND() in it advances the generator once, msduck
  // percentile-runtime-fraction rand-advancement)
  let fraction = if call.func is (PercentileCont | PercentileDisc) {
    eval(ctx, call.args[0])
  } else {
    Null
  }
  // partitions in order of first appearance, as lists of row indexes
  let parts : Array[(Array[@types.Value], Array[Int])] = []
  for i, r in rows {
    let key = call.partition.map(p => eval(ctx.with_row(r), p))
    let mut found = -1
    for pi, p in parts {
      if same_row(p.0, key, call.partition_collations) {
        found = pi
        break
      }
    }
    if found >= 0 {
      parts[found].1.push(i)
    } else {
      parts.push((key, [i]))
    }
  }
  for p in parts {
    let keyed = p.1.map(i => {
      (call.order.map(k => eval(ctx.with_row(rows[i]), k.expr)), i)
    })
    let sorted = sort_keyed(keyed, call.order)
    let idx = sorted.map(kv => kv.1)
    let keys = sorted.map(kv => kv.0)
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
    let mut dense = 0
    for j in 0..<n {
      if peer_start[j] == j {
        dense += 1
      }
      let row_ctx = ctx.with_row(part_rows[j])
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
          let off = if call.args.length() > 1 {
            match eval(row_ctx, call.args[1]).as_int64() {
              Some(o) if o >= 0L => o.to_int()
              _ =>
                raise @types.sql_error(
                  4114, "The offset provided to LAG or LEAD must be a non-negative integer.",
                )
            }
          } else {
            1
          }
          let target = if call.func is Lag { j - off } else { j + off }
          if target >= 0 && target < n {
            eval(ctx.with_row(part_rows[target]), call.args[0])
          } else if call.args.length() > 2 {
            eval(row_ctx, call.args[2])
          } else {
            Null
          }
        }
        FirstValue | LastValue | Agg(_, ..) => {
          let (fs, fe) = frame_bounds(row_ctx, call, j, n, peer_start, peer_end)
          match call.func {
            FirstValue =>
              if fs < fe {
                eval(ctx.with_row(part_rows[fs]), call.args[0])
              } else {
                Null
              }
            LastValue =>
              if fs < fe {
                eval(ctx.with_row(part_rows[fe - 1]), call.args[0])
              } else {
                Null
              }
            Agg(f, distinct~) => {
              let agg : @ir.AggCall = {
                func: f,
                arg: call.args.get(0),
                separator: None,
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
  result
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
