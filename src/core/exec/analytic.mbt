///|
/// Analytic additions: CHECKSUM_AGG, APPROX_COUNT_DISTINCT, PERCENTILE_CONT
/// / PERCENTILE_DISC and UNPIVOT (captured: harness/corpus/analytic/*).

///|
/// CHECKSUM_AGG: XOR of the (int) values; NULL over no values (captured:
/// 100 ^ 200 = 172, -1 ^ 5 = -6).
fn checksum_agg(values : Array[(@types.Value, Row)]) -> @types.Value {
  if values.is_empty() {
    return Null
  }
  let mut acc = 0
  for x in values {
    match x.0.as_int64() {
      Some(v) => acc = acc ^ v.to_int()
      None => ()
    }
  }
  Int(acc)
}

///|
/// Largest number of distinct values for which APPROX_COUNT_DISTINCT is
/// known to equal the exact count: captured over 8 types and 3 value
/// sequences, SQL Server's estimate first differs at 31 distinct values.
const APPROX_EXACT_LIMIT : Int = 30

///|
fn approx_count_distinct(
  ctx : Ctx,
  call : @ir.AggCall,
  rows : ArrayView[Row],
) -> @types.Value raise @types.SqlError {
  let distinct = agg_inputs(ctx, { ..call, distinct: true, }, rows)
  if distinct.length() > APPROX_EXACT_LIMIT {
    raise @types.not_supported(
      "APPROX_COUNT_DISTINCT over more than \{APPROX_EXACT_LIMIT} distinct values (SQL Server's HyperLogLog estimate is not reproduced)",
      number=@types.EMU_APPROX_COUNT_DISTINCT,
    )
  }
  BigInt(distinct.length().to_int64())
}

///|
/// PERCENTILE_CONT / PERCENTILE_DISC over one partition: `keys` are the
/// partition's WITHIN GROUP key values already sorted by that key.
fn percentile_value(
  ctx : Ctx,
  call : @ir.WindowCall,
  keys : Array[Array[@types.Value]],
) -> @types.Value raise @types.SqlError {
  let p = match eval(ctx, call.args[0]) {
    Null => None
    v =>
      match @types.cast(v, call.args[0].ty, Float) {
        Float(f) => Some(f)
        _ => None
      }
  }
  let p = match p {
    Some(f) if f >= 0.0 && f <= 1.0 => f
    _ =>
      raise @types.sql_error(
        8727, "Input parameter of percentile function is outside of range [0, 1].",
      )
  }
  let values = keys.filter(k => !(k[0] is Null)).map(k => k[0])
  let n = values.length()
  if n == 0 {
    return Null
  }
  let key_ty = call.order[0].expr.ty
  if call.func is PercentileDisc {
    // the first value whose cumulative distribution reaches p
    let mut i = 1
    while i < n && i.to_double() / n.to_double() < p {
      i += 1
    }
    return @types.cast(values[i - 1], key_ty, call.ty)
  }
  let at = (i : Int) => {
    match @types.cast(values[i], key_ty, Float) {
      Float(f) => f
      _ => 0.0
    }
  }
  // captured: row number rn = 1 + p * (n - 1); between the floor and the
  // ceiling rows the value is (c - rn) * v[f] + (rn - f) * v[c]
  let rn = 1.0 + p * (n - 1).to_double()
  let f = rn.floor()
  let c = rn.ceil()
  if f == c {
    return Float(at(f.to_int() - 1))
  }
  Float((c - rn) * at(f.to_int() - 1) + (rn - f) * at(c.to_int() - 1))
}

///|
fn run_unpivot(
  ctx : Ctx,
  input : @ir.Plan,
  keep : Array[Int],
  columns : Array[Int],
  names : Array[String],
  emit : (Row) -> Unit raise @types.SqlError,
) -> Unit raise @types.SqlError {
  stream(ctx, input, row => {
    for i, c in columns {
      let v = row[c]
      if v is Null {
        continue
      }
      let out : Row = keep.map(k => row[k])
      out.push(v)
      out.push(String(names[i]))
      emit(out)
    }
  })
}
