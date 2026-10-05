// ORDER BY on normalized keys: all of a row's ORDER BY keys encoded into
// one integer sequence that compares lexicographically in exactly the order
// `compare_sort_keys` gives key by key, so a comparison is one array
// compare instead of a per-key dispatch (Kuiper & Mühleisen, "These Rows
// Are Made for Sorting and That's Just What We'll Do", ICDE 2023: normalized
// keys; docs/design/performance.md).
//
// Per key: a NULL tag (0 for NULL, 1 otherwise, so NULLs sort first), then
// the value: integers and ticks as two order-preserving Ints, linguistic
// text keys (`@types.sort_key`, every element >= 0) followed by a -1
// terminator so a proper prefix still sorts first. DESC keys flip their
// segment with bitwise NOT (order-reversing, no overflow). Keys without an
// exact encoding (KeyValue: binary collations, sql_variant, ...) or with
// different kinds in one column use the general comparison instead.

///|
fn push_int64(out : Array[Int], x : Int64) -> Unit {
  out.push((x >> 32).to_int())
  // low half as unsigned, shifted into Int order
  out.push(((x & 0xFFFFFFFFL) - 0x80000000L).to_int())
}

///|
/// Normalized keys of `values` (one row per element), or None when some
/// key has no exact encoding.
fn normalized_keys(
  values : Array[Array[@types.Value]],
  keys : Array[@ir.SortKey],
) -> Array[Array[Int]]? {
  let ansi = keys.map(ansi_key)
  // key kind per column: 0 none yet, 1 integers, 2 ticks, 3 text
  let kinds = Array::make(keys.length(), 0)
  let out = []
  for row in values {
    let buf : Array[Int] = Array(capacity=keys.length() * 4)
    for i, v in row {
      let start = buf.length()
      let kind = match v {
        Null => {
          buf.push(0)
          0
        }
        TinyInt(x) | SmallInt(x) | Int(x) => {
          buf.push(1)
          push_int64(buf, x.to_int64())
          1
        }
        BigInt(x) => {
          buf.push(1)
          push_int64(buf, x)
          1
        }
        _ =>
          match @types.sort_key(v, collation?=keys[i].collation, ansi=ansi[i]) {
            KeyNull => {
              buf.push(0)
              0
            }
            KeyInt(x, _) => {
              buf.push(1)
              push_int64(buf, x)
              1
            }
            KeyTicks(x, _) => {
              buf.push(1)
              push_int64(buf, x)
              2
            }
            KeyText(ws, _) => {
              buf.push(1)
              for w in ws {
                buf.push(w)
              }
              buf.push(-1)
              3
            }
            KeyValue(_) => return None
          }
      }
      if kind > 0 {
        if kinds[i] == 0 {
          kinds[i] = kind
        } else if kinds[i] != kind {
          return None
        }
      }
      if keys[i].desc {
        for j in start..<buf.length() {
          buf[j] = buf[j].lnot()
        }
      }
    }
    out.push(buf)
  }
  Some(out)
}

///|
fn compare_normalized(a : Array[Int], b : Array[Int]) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a[i]
    let y = b[i]
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  a.length().compare(b.length())
}

///|
/// Input positions in stable ORDER BY order of the rows whose key values
/// are `values`, or None when the keys have no exact normalized encoding.
fn sort_order(
  values : Array[Array[@types.Value]],
  keys : Array[@ir.SortKey],
) -> Array[Int]? {
  guard normalized_keys(values, keys) is Some(ks) else { return None }
  let order = Array::makei(values.length(), i => i)
  stable_sort_by(order, (i, j) => compare_normalized(ks[i], ks[j]))
  Some(order)
}
