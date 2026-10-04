// UPPER / LOWER of UTF-16 code units under a collation's sort table version
// (data: case_data.mbt, generated from captures). Surrogates and
// supplementary characters are unchanged (captured: msduck unicode-case
// supplementary-letters, isolated surrogates).

///|
/// UPPER (or LOWER) of one UTF-16 code unit under collations of `version`
/// (0 or 100).
pub fn case_map_unit(unit : Int, upper : Bool, version : Int) -> Int {
  let table = if version >= 100 { case_map_v100 } else { case_map_v0 }
  let mut lo = 0
  let mut hi = table.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let (u, l, up) = table[mid]
    if u == unit {
      return if upper { up } else { l }
    } else if u < unit {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  unit
}

///|
/// UPPER / LOWER of a string under collation `c`, unit by unit.
pub fn case_map(s : String, upper : Bool, c : Collation) -> String {
  let out = StringBuilder()
  for i in 0..<s.length() {
    out.write_char(
      case_map_unit(s.code_unit_at(i).to_int(), upper, c.version).unsafe_to_char(),
    )
  }
  out.to_string()
}
