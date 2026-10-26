///|
let collation_property_rows : Ref[Array[(String, Int, Int, Int, Int)]?] = Ref(
  None,
)

///|
fn collation_property_data() -> Array[(String, Int, Int, Int, Int)] {
  if collation_property_rows.val is Some(rows) {
    return rows
  }
  let rows = []
  for line in collation_property_text.split("\n") {
    let f = line.split("|").collect()
    rows.push(
      (
        f[0].to_owned(),
        @tabletext.int(f[1]),
        @tabletext.int(f[2]),
        @tabletext.int(f[3]),
        @tabletext.int(f[4]),
      ),
    )
  }
  collation_property_rows.val = Some(rows)
  rows
}

///|
/// Metadata is available for every captured server collation, independently
/// of whether its comparison rules are implemented.
pub fn collation_properties(name : String) -> (Int, Int, Int, Int)? {
  let key = name.trim_end(chars=" ").to_owned().to_upper()
  let data = collation_property_data()
  let mut lo = 0
  let mut hi = data.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let (candidate, lcid, codepage, style, version) = data[mid]
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
