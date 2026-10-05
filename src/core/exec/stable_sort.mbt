///|
/// Stable merge sort in place: equal elements keep their input order, so
/// ORDER BY ties come out in scan order. Runs that are already in order
/// cost one comparison per merge (sorted input is O(n)). Used instead of
/// `Array::sort_by`, whose quicksort is unstable and falls back to heap
/// sort on periodic keys.
fn[T] stable_sort_by(xs : Array[T], cmp : (T, T) -> Int) -> Unit {
  let n = xs.length()
  if n < 2 {
    return
  }
  let buf = xs.copy()
  merge_sort(xs, buf, 0, n, cmp)
}

///|
/// Sorts xs[lo, hi), using buf[lo, hi) as scratch.
fn[T] merge_sort(
  xs : Array[T],
  buf : Array[T],
  lo : Int,
  hi : Int,
  cmp : (T, T) -> Int,
) -> Unit {
  if hi - lo <= 16 {
    // insertion sort: stable, fast on short runs
    for i in (lo + 1)..<hi {
      let x = xs[i]
      let mut j = i
      while j > lo && cmp(xs[j - 1], x) > 0 {
        xs[j] = xs[j - 1]
        j -= 1
      }
      xs[j] = x
    }
    return
  }
  let mid = lo + (hi - lo) / 2
  merge_sort(xs, buf, lo, mid, cmp)
  merge_sort(xs, buf, mid, hi, cmp)
  if cmp(xs[mid - 1], xs[mid]) <= 0 {
    return
  }
  for k in lo..<hi {
    buf[k] = xs[k]
  }
  let mut i = lo
  let mut j = mid
  for k in lo..<hi {
    // take from the left run on ties (stability)
    if j >= hi || (i < mid && cmp(buf[i], buf[j]) <= 0) {
      xs[k] = buf[i]
      i += 1
    } else {
      xs[k] = buf[j]
      j += 1
    }
  }
}
