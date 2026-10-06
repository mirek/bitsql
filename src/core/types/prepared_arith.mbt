///|
/// An arithmetic operation whose operand and result types are already bound.
pub type Arithmetic = (Value, Value) -> Value raise SqlError

///|
/// Select the common integer/string operation once, preserving arith_typed's
/// NULL handling. None leaves implicit conversions/other families on the
/// caller's existing direct arith_typed path.
/// The caller computes rt with arith_result_type before preparing this closure.
pub fn prepare_arith(
  op : ArithOp,
  ta : SqlType,
  tb : SqlType,
  rt : SqlType,
) -> Arithmetic? {
  let fa = ta.family()
  let fb = tb.family()
  if rt.family() == FInteger &&
    fa is (FInteger | FBit) &&
    fb is (FInteger | FBit) {
    let (lo, hi) = int_range(rt)
    return Some((a, b) => {
      if a is Null || b is Null {
        Null
      } else {
        int_arith_with_range(op, a, b, rt, lo, hi)
      }
    })
  }
  if rt.family() == FString && fa == FString && fb == FString {
    let unicode = rt.is_unicode()
    let collation = rt.collation().unwrap_or(default_collation)
    let limit = string_arith_limit(rt)
    return Some((a, b) => {
      if a is Null || b is Null {
        Null
      } else {
        string_arith(a, b, unicode, collation, limit)
      }
    })
  }
  None
}
