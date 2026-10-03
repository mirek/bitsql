///|
pub type Row = Array[@types.Value]

///|
/// Executes a plan to completion. CI-sized data makes materialization fine;
/// the statement-restart model (decisions.md) needs no suspension inside.
pub fn run(ctx : Ctx, plan : @ir.Plan) -> Array[Row] raise @types.SqlError {
  match plan {
    OneRow => [[]]
    Scan(scope~, id~, rowid~) =>
      (ctx.source)(scope, id).map(kv => {
        if rowid {
          let r = kv.1.copy()
          r.push(BigInt(kv.0))
          r
        } else {
          kv.1
        }
      })
    Join(kind, left, right, on, left_width~, right_width~) => {
      let ls = run(ctx, left)
      let rs = run(ctx, right)
      let out = []
      let right_matched = Array::make(rs.length(), false)
      for l in ls {
        let mut matched = false
        for j, r in rs {
          let row = l + r
          let ok = match on {
            Some(p) => is_true(eval(ctx.with_row(row), p))
            None => true
          }
          if ok {
            matched = true
            right_matched[j] = true
            out.push(row)
          }
        }
        if !matched && kind is (Left | Full) {
          out.push(l + Array::make(right_width, @types.Value::Null))
        }
      }
      if kind is (Right | Full) {
        for j, r in rs {
          if !right_matched[j] {
            out.push(Array::make(left_width, @types.Value::Null) + r)
          }
        }
      }
      out
    }
    Values(rows) => rows.map(r => r.map(e => eval(ctx, e)))
    Project(input, exprs) =>
      run(ctx, input).map(row => {
        let c = ctx.with_row(row)
        exprs.map(e => eval(c, e))
      })
    Filter(input, pred) => {
      let out = []
      for row in run(ctx, input) {
        if is_true(eval(ctx.with_row(row), pred)) {
          out.push(row)
        }
      }
      out
    }
    Sort(input, keys) => {
      let rows = run(ctx, input)
      let keyed = rows.map(row => {
        (keys.map(k => eval(ctx.with_row(row), k.expr)), row)
      })
      let mut failure : @types.SqlError? = None
      keyed.sort_by((a, b) => {
        for i, k in keys {
          let c = compare_for_sort(a.0[i], b.0[i], k.collation) catch {
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
      keyed.map(kv => kv.1)
    }
    Limit(input, offset, count) => {
      let rows = run(ctx, input)
      let off = match offset {
        Some(o) => eval(ctx, o).as_int64().unwrap_or(0L).to_int()
        None => 0
      }
      let cnt = match count {
        Some(c) => eval(ctx, c).as_int64().unwrap_or(0L).to_int()
        None => rows.length()
      }
      if off < 0 {
        raise @types.sql_error(
          10742, "The offset specified in a OFFSET clause may not be negative.",
        )
      }
      let start = @cmp.minimum(off, rows.length())
      let end = @cmp.minimum(start + @cmp.maximum(cnt, 0), rows.length())
      rows[start:end].to_owned()
    }
    Distinct(input, collations) => {
      let out : Array[Row] = []
      for row in run(ctx, input) {
        let mut dup = false
        for seen in out {
          if same_row(seen, row, collations) {
            dup = true
            break
          }
        }
        if !dup {
          out.push(row)
        }
      }
      out
    }
    UnionAll(parts) => {
      let out = []
      for p in parts {
        out.append(run(ctx, p))
      }
      out
    }
  }
}

///|
/// ORDER BY comparison: NULLs sort first ascending.
fn compare_for_sort(
  a : @types.Value,
  b : @types.Value,
  collation : @types.Collation?,
) -> Int raise @types.SqlError {
  match (a, b) {
    (Null, Null) => 0
    (Null, _) => -1
    (_, Null) => 1
    _ => @types.compare(a, b, collation?).unwrap_or(0)
  }
}

///|
/// DISTINCT / GROUP BY equality: NULLs are equal to each other.
fn same_row(
  a : Row,
  b : Row,
  collations : Array[@types.Collation?],
) -> Bool raise @types.SqlError {
  for i in 0..<a.length() {
    match (a[i], b[i]) {
      (Null, Null) => continue
      (Null, _) | (_, Null) => return false
      _ =>
        if @types.compare(a[i], b[i], collation?=collations[i]) != Some(0) {
          return false
        }
    }
  }
  true
}
