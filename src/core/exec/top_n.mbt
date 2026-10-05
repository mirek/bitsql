// TOP n over ORDER BY without sorting every row: a bounded max-heap keeps
// the n smallest (key values, input position) pairs, so the result is
// exactly the first n rows of the stable sort (`sort_prepared`), in
// O(rows log n), and only compared rows cost anything (no sort keys are
// built; DuckDB's Top-N compares against the heap boundary the same way).
// The keys, the count and their errors are evaluated as `Top(Sort(..))`
// evaluates them: every row's key values first, then the count.
// docs/design/performance.md.

///|
/// The first `n` rows of the stable ORDER BY sort, comparing key values
/// (`compare_keys`, the order the sort keys encode) instead of building
/// sort keys for every row: only rows that enter the heap are kept.
fn top_n_values(
  values : Array[Array[@types.Value]],
  rows : Array[Row],
  n : Int,
  keys : Array[@ir.SortKey],
) -> Array[Row] raise @types.SqlError {
  if n <= 0 {
    return []
  }
  let heap : Array[Int] = []
  let greater = (i : Int, j : Int) => {
    let c = compare_keys(values[i], values[j], keys)
    c > 0 || (c == 0 && i > j)
  }
  for i in 0..<values.length() {
    if heap.length() < n {
      heap.push(i)
      let mut at = heap.length() - 1
      while at > 0 {
        let up = (at - 1) / 2
        if !greater(heap[at], heap[up]) {
          break
        }
        let t = heap[at]
        heap[at] = heap[up]
        heap[up] = t
        at = up
      }
    } else if greater(heap[0], i) {
      heap[0] = i
      let mut at = 0
      while true {
        let l = at * 2 + 1
        if l >= heap.length() {
          break
        }
        let r = l + 1
        let big = if r < heap.length() && greater(heap[r], heap[l]) {
          r
        } else {
          l
        }
        if !greater(heap[big], heap[at]) {
          break
        }
        let t = heap[at]
        heap[at] = heap[big]
        heap[big] = t
        at = big
      }
    }
  }
  let mut failure : @types.SqlError? = None
  stable_sort_by(heap, (i, j) => {
    let c = compare_keys(values[i], values[j], keys) catch {
      e => {
        failure = Some(e)
        0
      }
    }
    if c != 0 {
      c
    } else {
      i.compare(j)
    }
  })
  if failure is Some(e) {
    raise e
  }
  heap.map(i => rows[i])
}
