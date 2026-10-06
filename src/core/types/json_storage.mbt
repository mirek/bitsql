// Native JSON construction and mutation allocation. Captures in sql2025:
// json-binary-{size,boundaries}, json-*-allocation, json-allocation-*, and
// json-property-slots. This models retained storage, not a binary serializer.

///|
fn json_storage_string(text : String) -> Int {
  let n = utf8_length(text)
  if n == 0 {
    return 0
  }
  let mut length_bytes = 1
  let mut remaining = n >> 7
  while remaining > 0 {
    length_bytes += 1
    remaining = remaining >> 7
  }
  n + 1 + length_bytes
}

///|
fn json_storage_number(text : String) -> Int raise SqlError {
  guard Decimal::parse(text[:]) is Some(d) else {
    raise internal("noncanonical native JSON number")
  }
  let coef = d.coef()
  if d.scale() == 0 {
    if coef.compare_int(-536870912) >= 0 && coef.compare_int(536870911) <= 0 {
      return 0
    }
    if coef >= @bigint.BigInt::from_int64(-9223372036854775808L) &&
      coef <= @bigint.BigInt::from_int64(9223372036854775807L) {
      return 9
    }
  }
  let bits = big_abs(coef).bit_length()
  5 + 4 * (if bits == 0 { 1 } else { (bits + 31) / 32 })
}

///|
priv enum JsonStorageNode {
  NScalar(Int, String)
  NDeleted
  NArray(Array[JsonStorageNode], Int)
  NObject(Array[(String, JsonStorageNode)], Int)
} derive(Debug, Eq)

///|
fn JsonStorageNode::requires_wide(
  self : JsonStorageNode,
  keys : Set[String],
) -> Bool {
  match self {
    NArray(children, _) =>
      children.length() > 65535 || children.any(c => c.requires_wide(keys))
    NObject(children, _) => {
      for (key, child) in children {
        keys.add(key)
        if keys.length() > 32768 || child.requires_wide(keys) {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
fn JsonTypeParser::storage_node(
  self : JsonTypeParser,
  depth : Int,
) -> JsonStorageNode raise SqlError {
  self.ws()
  match self.peek() {
    0x7B => {
      if depth >= 128 {
        raise json_type_depth_error()
      }
      self.pos += 1
      self.ws()
      let children = []
      while self.peek() != 0x7D {
        if !children.is_empty() {
          if self.peek() != 0x2C {
            raise self.fail_at(self.pos)
          }
          self.pos += 1
          self.ws()
        }
        if self.peek() != 0x22 {
          raise self.fail_at(self.pos)
        }
        let key = self.string()
        self.ws()
        if self.peek() != 0x3A {
          raise self.fail_at(self.pos)
        }
        self.pos += 1
        children.push((key, self.storage_node(depth + 1)))
        self.ws()
      }
      self.pos += 1
      NObject(children, children.length())
    }
    0x5B => {
      if depth >= 128 {
        raise json_type_depth_error()
      }
      self.pos += 1
      self.ws()
      let children = []
      while self.peek() != 0x5D {
        if !children.is_empty() {
          if self.peek() != 0x2C {
            raise self.fail_at(self.pos)
          }
          self.pos += 1
        }
        children.push(self.storage_node(depth + 1))
        self.ws()
      }
      self.pos += 1
      NArray(children, children.length())
    }
    0x22 => {
      let value = self.string()
      let out = StringBuilder()
      write_json_type_string(out, value)
      NScalar(json_storage_string(value), out.to_string())
    }
    0x74 | 0x66 | 0x6E => {
      let word = match self.peek() {
        0x74 => "true"
        0x66 => "false"
        _ => "null"
      }
      self.literal(word, StringBuilder())
      NScalar(0, word)
    }
    c if c == 0x2D || (c >= 0x30 && c <= 0x39) => {
      let value = self.number()
      NScalar(json_storage_number(value), value)
    }
    _ => raise self.fail_at(self.pos)
  }
}

///|
fn json_storage_tree(canonical : String) -> JsonStorageNode raise SqlError {
  let parser : JsonTypeParser = { b: utf8_bytes(canonical), pos: 0, }
  let node = parser.storage_node(0)
  parser.ws()
  if parser.pos != parser.b.length() {
    raise parser.fail_at(parser.pos)
  }
  node
}

///|
priv struct JsonAllocator {
  wide : Bool
  mut end : Int
  keys : Set[String]
  mut dictionary_offset : Int?
  mut dictionary_capacity : Int
  mut dictionary_indexed : Bool
}

///|
fn JsonAllocator::container_bytes(
  self : JsonAllocator,
  capacity : Int,
  object : Bool,
) -> Int {
  (if self.wide { 6 } else { 4 }) +
  (if object { if self.wide { 8 } else { 6 } } else { 4 }) * capacity
}

///|
fn JsonAllocator::dictionary_bytes(
  self : JsonAllocator,
  capacity : Int,
  indexed : Bool,
) -> Int {
  (if self.wide { 6 } else { 4 }) +
  (8 + (if indexed { if self.wide { 4 } else { 2 } } else { 0 })) * capacity
}

///|
fn JsonAllocator::container_capacity(
  self : JsonAllocator,
  old : Int,
  object : Bool,
) -> Int {
  let n = json_grow_capacity(old)
  let limit = if object { 32767 } else { 65535 }
  if !self.wide && n > limit {
    limit
  } else {
    n
  }
}

///|
fn JsonAllocator::allocate(
  self : JsonAllocator,
  bytes : Int,
) -> Int raise SqlError {
  if bytes < 0 || self.end.to_int64() + bytes.to_int64() > 2147483631L {
    raise emulator_error(
      EMU_WORK_BUDGET,
      "native JSON storage exceeded the size budget",
    )
  }
  let offset = self.end
  self.end += bytes
  offset
}

///|
/// Captured capacities grow by 120%, with 2..15 additional slots.
fn json_grow_capacity(capacity : Int) -> Int {
  capacity +
  (if capacity < 2 {
    2
  } else if capacity >= 13 {
    15
  } else {
    capacity * 6 / 5
  })
}

///|
fn JsonAllocator::reserve_dictionary(
  self : JsonAllocator,
  count : Int,
) -> Unit raise SqlError {
  let old = self.dictionary_capacity
  if count <= old {
    return
  }
  let mut capacity = old
  while capacity < count {
    capacity = json_grow_capacity(capacity)
    if !self.wide && capacity > 32767 {
      capacity = 32767
    }
  }
  let old_bytes = self.dictionary_bytes(old, self.dictionary_indexed)
  let indexed = self.dictionary_indexed || count > 1024
  let new_bytes = self.dictionary_bytes(capacity, indexed)
  if self.dictionary_offset is Some(offset) && offset + old_bytes == self.end {
    ignore(self.allocate(new_bytes - old_bytes))
  } else {
    self.dictionary_offset = Some(self.allocate(new_bytes))
  }
  self.dictionary_capacity = capacity
  self.dictionary_indexed = indexed
}

///|
fn JsonAllocator::key(
  self : JsonAllocator,
  key : String,
  direct? : Bool = false,
) -> Unit raise SqlError {
  if self.keys.contains(key) {
    return
  }
  // A spare slot can postpone the index until the next new-key insertion.
  // Existing-key replacement/deletion does not materialize it.
  if !self.dictionary_indexed &&
    self.keys.length() > 1024 &&
    self.dictionary_offset is Some(offset) {
    let capacity = self.dictionary_capacity
    if offset + self.dictionary_bytes(capacity, false) == self.end {
      ignore(self.allocate((if self.wide { 4 } else { 2 }) * capacity))
    } else {
      self.dictionary_offset = Some(
        self.allocate(self.dictionary_bytes(capacity, true)),
      )
    }
    self.dictionary_indexed = true
  }
  if direct {
    self.reserve_dictionary(self.keys.length() + 1)
  }
  self.keys.add(key)
  ignore(self.allocate(json_storage_string(key)))
}

///|
fn JsonAllocator::clone_node(
  self : JsonAllocator,
  node : JsonStorageNode,
) -> JsonStorageNode raise SqlError {
  match node {
    NDeleted => NDeleted
    NScalar(bytes, _) => {
      ignore(self.allocate(bytes))
      node
    }
    NArray(children, _) => {
      let copy = children.map(c => self.clone_node(c))
      if !copy.is_empty() {
        ignore(self.allocate(self.container_bytes(copy.length(), false)))
      }
      NArray(copy, copy.length())
    }
    NObject(children, _) => {
      let copy = children.map(pair => {
        let (key, value) = pair
        self.key(key)
        (key, self.clone_node(value))
      })
      if !copy.is_empty() {
        ignore(self.allocate(self.container_bytes(copy.length(), true)))
      }
      NObject(copy, copy.length())
    }
  }
}

///|
fn JsonAllocator::fresh(
  self : JsonAllocator,
  node : JsonStorageNode,
) -> JsonStorageNode raise SqlError {
  let result = self.clone_node(node)
  self.reserve_dictionary(self.keys.length())
  result
}

///|
fn JsonAllocator::replace(
  self : JsonAllocator,
  before : JsonStorageNode,
  after : JsonStorageNode,
) -> JsonStorageNode raise SqlError {
  match (before, after) {
    (NScalar(old, _), NScalar(bytes, _)) => {
      if bytes > old {
        ignore(self.allocate(bytes))
      }
      after
    }
    _ => self.fresh(after)
  }
}

///|
fn JsonStorageNode::child(
  self : JsonStorageNode,
  step : @json.Step,
) -> JsonStorageNode? {
  match (self, step) {
    (NArray(children, _), Index(i)) => children.get(i)
    (NObject(children, _), Key(key)) => {
      for (k, v) in children {
        if k == key {
          return Some(v)
        }
      }
      None
    }
    _ => None
  }
}

///|
fn JsonAllocator::put(
  self : JsonAllocator,
  parent : JsonStorageNode,
  step : @json.Step,
  value : JsonStorageNode?,
) -> JsonStorageNode raise SqlError {
  match (parent, step) {
    (NObject(children, capacity), Key(key)) => {
      let out = children.copy()
      let mut found = -1
      let mut free = -1
      for i, pair in children {
        let (k, v) = pair
        if v is NDeleted {
          if free < 0 {
            free = i
          }
        } else if k == key {
          found = i
        }
      }
      if found >= 0 {
        out[found] = (key, value.unwrap_or(NDeleted))
      } else if value is Some(replacement) {
        if free >= 0 {
          out[free] = (key, replacement)
        } else {
          out.push((key, replacement))
        }
      }
      let capacity = if out.length() > capacity {
        let next = self.container_capacity(capacity, true)
        ignore(self.allocate(self.container_bytes(next, true)))
        next
      } else {
        capacity
      }
      NObject(out, capacity)
    }
    (NArray(children, capacity), Index(i)) if i >= 0 && i < children.length() => {
      let out = children.copy()
      if value is Some(replacement) {
        out[i] = replacement
      }
      NArray(out, capacity)
    }
    _ => parent
  }
}

///|
fn JsonAllocator::insert(
  self : JsonAllocator,
  parent : JsonStorageNode,
  step : @json.Step,
  value : JsonStorageNode,
) -> JsonStorageNode raise SqlError {
  guard parent is NObject(_, _) && step is Key(key) else { return parent }
  // Scalar property insertion reserves its key first. Container values are
  // cloned before registration, which can force dictionary relocation.
  let replacement = match value {
    NScalar(_, _) => {
      self.key(key, direct=true)
      self.fresh(value)
    }
    _ => {
      let v = self.fresh(value)
      self.key(key, direct=true)
      v
    }
  }
  self.put(parent, step, Some(replacement))
}

///|
fn JsonAllocator::update(
  self : JsonAllocator,
  before : JsonStorageNode,
  after : JsonStorageNode,
  steps : ArrayView[@json.Step],
  append : Bool,
) -> JsonStorageNode raise SqlError {
  if steps.is_empty() {
    if append {
      match (before, after) {
        (NArray(old, capacity), NArray(next, _)) if next.length() ==
          old.length() + 1 => {
          let out = old.copy()
          out.push(self.fresh(next[old.length()]))
          let capacity = if out.length() > capacity {
            let n = self.container_capacity(capacity, false)
            ignore(self.allocate(self.container_bytes(n, false)))
            n
          } else {
            capacity
          }
          return NArray(out, capacity)
        }
        _ => return before
      }
    }
    return self.replace(before, after)
  }
  let step = steps[0]
  let old = before.child(step)
  let next = after.child(step)
  match (old, next) {
    (Some(_), None) if steps.length() == 1 && !append =>
      self.put(before, step, None)
    (None, Some(value)) if steps.length() == 1 => {
      if append {
        raise sql_error(
          13656,
          "JSON data type cannot be used when its feature switch is off. ",
          state=8,
        )
      }
      self.insert(before, step, value)
    }
    (Some(old), Some(next)) => {
      let replacement = self.update(old, next, steps[1:], append)
      if replacement == old {
        before
      } else {
        self.put(before, step, Some(replacement))
      }
    }
    _ => before
  }
}

///|
/// Native JSON text plus immutable allocation state. Child arrays and the key
/// set are never mutated after publication, preserving assignment/snapshots.
pub struct JsonData {
  priv text : String
  priv wide : Bool
  priv root : JsonStorageNode
  priv end : Int
  priv keys : Set[String]
  priv dictionary_offset : Int?
  priv dictionary_capacity : Int
  priv dictionary_indexed : Bool
} derive(Debug, Eq)

///|
fn JsonData::from_canonical(
  canonical : String,
  force_wide? : Bool = false,
) -> JsonData raise SqlError {
  let tree = json_storage_tree(canonical)
  let wide = force_wide || tree.requires_wide(Set([]))
  let state : JsonAllocator = {
    wide,
    end: 2,
    keys: Set([]),
    dictionary_offset: None,
    dictionary_capacity: 0,
    dictionary_indexed: false,
  }
  let root = state.clone_node(tree)
  state.dictionary_capacity = state.keys.length()
  state.dictionary_indexed = state.keys.length() > 1024
  if !state.keys.is_empty() {
    state.dictionary_offset = Some(
      state.allocate(
        state.dictionary_bytes(
          state.dictionary_capacity,
          state.dictionary_indexed,
        ),
      ),
    )
  }
  {
    text: canonical,
    wide,
    root,
    end: state.end,
    keys: state.keys,
    dictionary_offset: state.dictionary_offset,
    dictionary_capacity: state.dictionary_capacity,
    dictionary_indexed: state.dictionary_indexed,
  }
}

///|
pub fn JsonData::parse(text : String) -> JsonData raise SqlError {
  JsonData::from_canonical(json_type_normalize(text))
}

///|
/// Account for a successful JSON_MODIFY result. SQL path/value semantics have
/// already been checked; the result text is normalized before tracking storage.
pub fn JsonData::modified(
  self : JsonData,
  text : String,
  path : String,
) -> JsonData raise SqlError {
  let canonical = json_type_normalize(text)
  let p = @json.parse_path(path, allow_append=true) catch {
    @json.JsonError(number, state, message) =>
      raise sql_error(number, message, state~)
  }
  if p.steps.any(s => s.is_multi()) {
    raise not_supported("native JSON allocation for a multi-value path")
  }
  let tree = json_storage_tree(canonical)
  // Widening rebuilds the current live document before applying the mutation.
  // Dead allocations disappear; all containers and dictionary entries widen.
  let keys = self.keys.copy()
  let requires_wide = tree.requires_wide(keys)
  let dictionary_grows_wide = keys.length() > self.keys.length() &&
    keys.length() >= 32768
  if !self.wide && (requires_wide || dictionary_grows_wide) {
    return JsonData::from_canonical(self.text, force_wide=true).modified(
      canonical, path,
    )
  }
  let state : JsonAllocator = {
    wide: self.wide,
    end: self.end,
    keys: self.keys.copy(),
    dictionary_offset: self.dictionary_offset,
    dictionary_capacity: self.dictionary_capacity,
    dictionary_indexed: self.dictionary_indexed,
  }
  let root = state.update(self.root, tree, p.steps[:], p.append)
  {
    text: root.to_text(),
    wide: self.wide,
    root,
    end: state.end,
    keys: state.keys,
    dictionary_offset: state.dictionary_offset,
    dictionary_capacity: state.dictionary_capacity,
    dictionary_indexed: state.dictionary_indexed,
  }
}

///|
pub fn JsonData::text(self : JsonData) -> String {
  self.text
}

///|
pub fn JsonData::storage_bytes(self : JsonData) -> Int {
  self.end + 16
}

///|
/// Size of fresh construction, excluding any retained mutation allocations.
pub fn json_constructed_storage_bytes(canonical : String) -> Int raise SqlError {
  JsonData::from_canonical(canonical).end + 16
}

///|
fn JsonStorageNode::write(self : JsonStorageNode, out : StringBuilder) -> Unit {
  match self {
    NScalar(_, text) => out.write_string(text)
    NDeleted => ()
    NArray(children, _) => {
      out.write_char('[')
      for i, child in children {
        if i > 0 {
          out.write_char(',')
        }
        child.write(out)
      }
      out.write_char(']')
    }
    NObject(children, _) => {
      out.write_char('{')
      let mut first = true
      for (key, value) in children {
        if value is NDeleted {
          continue
        }
        if !first {
          out.write_char(',')
        }
        first = false
        write_json_type_string(out, key)
        out.write_char(':')
        value.write(out)
      }
      out.write_char('}')
    }
  }
}

///|
fn JsonStorageNode::to_text(self : JsonStorageNode) -> String {
  let out = StringBuilder()
  self.write(out)
  out.to_string()
}

///|
/// Concrete paths of live native values, including containers and JSON null.
/// Index maintenance reads the immutable storage tree, without reparsing text.
pub fn JsonData::index_paths(self : JsonData) -> Array[String] {
  let out = []
  fn walk(node : JsonStorageNode, path : String) -> Unit {
    if node is NDeleted {
      return
    }
    out.push(path)
    match node {
      NObject(children, _) =>
        for (key, child) in children {
          walk(child, path + "." + @json.quote(key))
        }
      NArray(children, _) =>
        for i, child in children {
          walk(child, path + "[" + i.to_string() + "]")
        }
      _ => ()
    }
  }
  walk(self.root, "$")
  out
}

///|
/// Scalar entries of the JSON internal table. Empty containers have no entry;
/// the first occurrence of each object key supplies its indexed subtree.
pub fn JsonData::index_scalar_paths(self : JsonData) -> Array[String] {
  let out = []
  fn walk(node : JsonStorageNode, path : String) -> Unit {
    match node {
      NDeleted => ()
      NObject(children, _) => {
        let seen : Set[String] = Set([])
        for (key, child) in children {
          if child is NDeleted || seen.contains(key) {
            continue
          }
          seen.add(key)
          walk(child, path + "." + @json.quote(key))
        }
      }
      NArray(children, _) =>
        for i, child in children {
          walk(child, path + "[" + i.to_string() + "]")
        }
      _ => out.push(path)
    }
  }
  walk(self.root, "$")
  out
}
