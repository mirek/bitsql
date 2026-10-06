///|
/// Metadata is available for every captured server collation, independently
/// of whether its comparison rules are implemented.
pub fn collation_properties(name : String) -> (Int, Int, Int, Int)? {
  let key = name.trim_end(chars=" ").to_owned().to_upper()
  let mut lo = 0
  let mut hi = collation_property_data.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let (candidate, lcid, codepage, style, version) = collation_property_data[mid]
    let order = key.lexical_compare(candidate)
    if order == 0 {
      return Some((lcid, codepage, style, version))
    }
    if order < 0 {
      hi = mid
    } else {
      lo = mid + 1
    }
  }
  None
}
