// Open-addressing hash table from Int64 keys to non-negative Int values
// (linear probing, Fibonacci hashing, power-of-two capacity) for hash
// joins and integer grouping: unboxed key and value arrays instead of the
// builtin `Map`'s per-entry objects and insertion-order links. The usual
// hash-table design for joins and aggregation, e.g. DuckDB's aggregate hash
// table (docs/design/performance.md).

///|
priv struct IntTable {
  mut keys : FixedArray[Int64]
  /// value + 1 per slot; 0 marks an empty slot
  mut vals : FixedArray[Int]
  mut size : Int
  mut shift : Int
}

///|
fn IntTable::new(expected : Int) -> IntTable {
  let mut cap = 16
  let mut shift = 60
  while cap < expected * 2 {
    cap = cap * 2
    shift = shift - 1
  }
  {
    keys: FixedArray::make(cap, 0L),
    vals: FixedArray::make(cap, 0),
    size: 0,
    shift,
  }
}

///|
fn IntTable::slot(self : IntTable, key : Int64) -> Int {
  ((key.reinterpret_as_uint64() * 0x9E3779B97F4A7C15UL) >> self.shift).to_int()
}

///|
/// The value under `key`, or -1.
fn IntTable::get(self : IntTable, key : Int64) -> Int {
  let mask = self.vals.length() - 1
  let mut i = self.slot(key)
  while self.vals[i] != 0 {
    if self.keys[i] == key {
      return self.vals[i] - 1
    }
    i = (i + 1) & mask
  }
  -1
}

///|
/// Stores `value` (>= 0) under `key`, replacing any previous value.
fn IntTable::set(self : IntTable, key : Int64, value : Int) -> Unit {
  if (self.size + 1) * 2 > self.vals.length() {
    self.grow()
  }
  let mask = self.vals.length() - 1
  let mut i = self.slot(key)
  while self.vals[i] != 0 {
    if self.keys[i] == key {
      self.vals[i] = value + 1
      return
    }
    i = (i + 1) & mask
  }
  self.keys[i] = key
  self.vals[i] = value + 1
  self.size += 1
}

///|
fn IntTable::grow(self : IntTable) -> Unit {
  let keys = self.keys
  let vals = self.vals
  self.keys = FixedArray::make(keys.length() * 2, 0L)
  self.vals = FixedArray::make(vals.length() * 2, 0)
  self.shift -= 1
  self.size = 0
  for i in 0..<vals.length() {
    if vals[i] != 0 {
      self.set(keys[i], vals[i] - 1)
    }
  }
}
