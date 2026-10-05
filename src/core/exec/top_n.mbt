// TOP n over ORDER BY without sorting every row: a bounded max-heap keeps
// the n smallest (order keys, input position) pairs, so the result is
// exactly the first n rows of the stable sort (`sort_prepared`), in
// O(rows log n). The keys, the count and their errors are evaluated as
// `Top(Sort(..))` evaluates them: every row's keys first, then the count.
// docs/design/performance.md.

///|
/// ORDER BY comparison of two prepared key rows (`sort_prepared`'s order).
fn compare_prepared(
  a : Array[@types.SortKey],
  b : Array[@types.SortKey],
  keys : Array[@ir.SortKey],
  ansi : Array[Bool],
) -> Int raise @types.SqlError {
  for i, k in keys {
    let c = @types.compare_sort_keys(
      a[i],
      b[i],
      collation?=k.collation,
      ansi=ansi[i],
    )
    if c != 0 {
      return if k.desc { -c } else { c }
    }
  }
  0
}

///|
/// The first `n` items of the stable ORDER BY sort of `prepared`.
fn[T] top_n_prepared(
  prepared : Array[(Array[@types.SortKey], T)],
  n : Int,
  keys : Array[@ir.SortKey],
  ansi : Array[Bool],
) -> Array[T] raise @types.SqlError {
  if n <= 0 {
    return []
  }
  // (position, keys) entries; heap[0] is the greatest kept entry
  let heap : Array[Int] = []
  let greater = (i : Int, j : Int) => {
    let c = compare_prepared(prepared[i].0, prepared[j].0, keys, ansi)
    c > 0 || (c == 0 && i > j)
  }
  let sift_down = (start : Int) => {
    let mut at = start
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
  for i in 0..<prepared.length() {
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
      sift_down(0)
    }
  }
  let mut failure : @types.SqlError? = None
  stable_sort_by(heap, (i, j) => {
    let c = compare_prepared(prepared[i].0, prepared[j].0, keys, ansi) catch {
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
  heap.map(i => prepared[i].1)
}
