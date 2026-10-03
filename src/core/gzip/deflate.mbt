// A port of zlib 1.3.1's deflate at compression level 6 (deflate_slow,
// windowBits 15, memLevel 8, default strategy): COMPRESS must reproduce SQL
// Server's bytes exactly, and those are zlib's (checked against captures of
// 6 short strings, 100000 'a', 20000 sentences and pseudo-random text where
// levels 4-9 all differ: harness/corpus/conversion/compress.cases.json).
// Names follow deflate.c / trees.c so the two can be compared line by line.

///|
const WSIZE : Int = 32768

///|
const WMASK : Int = 32767

///|

///|
const HASH_SIZE : Int = 32768

///|
const HASH_MASK : Int = 32767

///|
/// (HASH_BITS + MIN_MATCH - 1) / MIN_MATCH
const HASH_SHIFT : Int = 5

///|
const MIN_MATCH : Int = 3

///|
const MAX_MATCH : Int = 258

///|
const MIN_LOOKAHEAD : Int = 262

///|
const MAX_DIST : Int = 32506

///|
const WIN_INIT : Int = 258

///|
const TOO_FAR : Int = 4096

///|
/// 1 << (memLevel + 6)
const LIT_BUFSIZE : Int = 16384

// level 6 configuration

///|
const GOOD_MATCH : Int = 8

///|
const MAX_LAZY : Int = 16

///|
const NICE_MATCH : Int = 128

///|
const MAX_CHAIN : Int = 128

// trees.c

///|
const LENGTH_CODES : Int = 29

///|
const LITERALS : Int = 256

///|
const L_CODES : Int = 286

///|
const D_CODES : Int = 30

///|
const BL_CODES : Int = 19

///|
const HEAP_SIZE : Int = 573

///|
const MAX_BITS : Int = 15

///|
const MAX_BL_BITS : Int = 7

///|
const END_BLOCK : Int = 256

///|
const REP_3_6 : Int = 16

///|
const REPZ_3_10 : Int = 17

///|
const REPZ_11_138 : Int = 18

///|
let extra_lbits : FixedArray[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
let extra_dbits : FixedArray[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
let extra_blbits : FixedArray[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7,
]

///|
let bl_order : FixedArray[Int] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

///|
/// Huffman tree storage (zlib's ct_data with the unions split).
priv struct Tree {
  freq : FixedArray[Int]
  code : FixedArray[Int]
  len : FixedArray[Int]
  dad : FixedArray[Int]
}

///|
fn Tree::new(n : Int) -> Tree {
  {
    freq: FixedArray::make(n, 0),
    code: FixedArray::make(n, 0),
    len: FixedArray::make(n, 0),
    dad: FixedArray::make(n, 0),
  }
}

///|
priv struct StaticTables {
  ltree : Tree
  dtree : Tree
  length_code : FixedArray[Int]
  dist_code : FixedArray[Int]
  base_length : FixedArray[Int]
  base_dist : FixedArray[Int]
}

///|
fn bi_reverse(code : Int, len : Int) -> Int {
  let mut c = code
  let mut res = 0
  for _ in 0..<len {
    res = (res << 1) | (c & 1)
    c = c >> 1
  }
  res
}

///|
fn gen_codes(tree : Tree, max_code : Int, bl_count : FixedArray[Int]) -> Unit {
  let next_code = FixedArray::make(MAX_BITS + 1, 0)
  let mut code = 0
  for bits in 1..<=MAX_BITS {
    code = (code + bl_count[bits - 1]) << 1
    next_code[bits] = code
  }
  for n in 0..<=max_code {
    let len = tree.len[n]
    if len == 0 {
      continue
    }
    tree.code[n] = bi_reverse(next_code[len], len)
    next_code[len] += 1
  }
}

///|
let static_tables : StaticTables = {
  let length_code = FixedArray::make(256, 0)
  let dist_code = FixedArray::make(512, 0)
  let base_length = FixedArray::make(LENGTH_CODES, 0)
  let base_dist = FixedArray::make(D_CODES, 0)
  let mut length = 0
  let mut code = 0
  while code < LENGTH_CODES - 1 {
    base_length[code] = length
    for _ in 0..<(1 << extra_lbits[code]) {
      length_code[length] = code
      length += 1
    }
    code += 1
  }
  length_code[length - 1] = code
  let mut dist = 0
  code = 0
  while code < 16 {
    base_dist[code] = dist
    for _ in 0..<(1 << extra_dbits[code]) {
      dist_code[dist] = code
      dist += 1
    }
    code += 1
  }
  dist = dist >> 7
  while code < D_CODES {
    base_dist[code] = dist << 7
    for _ in 0..<(1 << (extra_dbits[code] - 7)) {
      dist_code[256 + dist] = code
      dist += 1
    }
    code += 1
  }
  let bl_count = FixedArray::make(MAX_BITS + 1, 0)
  let ltree = Tree::new(L_CODES + 2)
  for n in 0..<=287 {
    let l = if n <= 143 {
      8
    } else if n <= 255 {
      9
    } else if n <= 279 {
      7
    } else {
      8
    }
    ltree.len[n] = l
    bl_count[l] += 1
  }
  gen_codes(ltree, L_CODES + 1, bl_count)
  let dtree = Tree::new(D_CODES)
  for n in 0..<D_CODES {
    dtree.len[n] = 5
    dtree.code[n] = bi_reverse(n, 5)
  }
  { ltree, dtree, length_code, dist_code, base_length, base_dist, }
}

///|
fn d_code(dist : Int) -> Int {
  if dist < 256 {
    static_tables.dist_code[dist]
  } else {
    static_tables.dist_code[256 + (dist >> 7)]
  }
}

///|
/// LSB-first bit writer (zlib's bi_buf/bi_valid with put_short, which
/// produces the same byte stream).
priv struct BitWriter {
  out : @buffer.Buffer
  mut bits : Int
  mut count : Int
}

///|
fn BitWriter::send_bits(self : BitWriter, value : Int, length : Int) -> Unit {
  self.bits = self.bits | ((value & ((1 << length) - 1)) << self.count)
  self.count += length
  while self.count >= 8 {
    self.out.write_byte((self.bits & 0xFF).to_byte())
    self.bits = self.bits >> 8
    self.count -= 8
  }
}

///|
fn BitWriter::windup(self : BitWriter) -> Unit {
  if self.count > 0 {
    self.out.write_byte((self.bits & 0xFF).to_byte())
  }
  self.bits = 0
  self.count = 0
}

///|
/// A tree description (zlib's tree_desc + static_tree_desc).
priv struct Desc {
  tree : Tree
  stree : Tree?
  extra : FixedArray[Int]
  extra_base : Int
  elems : Int
  max_length : Int
  mut max_code : Int
}

///|
priv struct Deflater {
  input : BytesView
  mut next_in : Int
  window : FixedArray[Int]
  prev : FixedArray[Int]
  head : FixedArray[Int]
  mut ins_h : Int
  mut strstart : Int
  mut block_start : Int
  mut lookahead : Int
  mut insert : Int
  mut match_length : Int
  mut prev_match : Int
  mut match_available : Bool
  mut match_start : Int
  mut prev_length : Int
  mut high_water : Int
  // trees
  l_desc : Desc
  d_desc : Desc
  bl_desc : Desc
  bl_count : FixedArray[Int]
  heap : FixedArray[Int]
  mut heap_len : Int
  mut heap_max : Int
  depth : FixedArray[Int]
  sym_buf : FixedArray[Int]
  mut sym_next : Int
  mut opt_len : Int64
  mut static_len : Int64
  bw : BitWriter
}

///|
fn Deflater::new(input : BytesView, out : @buffer.Buffer) -> Deflater {
  let ltree = Tree::new(HEAP_SIZE)
  let dtree = Tree::new(2 * D_CODES + 1)
  let bltree = Tree::new(2 * BL_CODES + 1)
  let s : Deflater = {
    input,
    next_in: 0,
    window: FixedArray::make(2 * WSIZE, 0),
    prev: FixedArray::make(WSIZE, 0),
    head: FixedArray::make(HASH_SIZE, 0),
    ins_h: 0,
    strstart: 0,
    block_start: 0,
    lookahead: 0,
    insert: 0,
    match_length: MIN_MATCH - 1,
    prev_match: 0,
    match_available: false,
    match_start: 0,
    prev_length: MIN_MATCH - 1,
    high_water: 0,
    l_desc: {
      tree: ltree,
      stree: Some(static_tables.ltree),
      extra: extra_lbits,
      extra_base: LITERALS + 1,
      elems: L_CODES,
      max_length: MAX_BITS,
      max_code: 0,
    },
    d_desc: {
      tree: dtree,
      stree: Some(static_tables.dtree),
      extra: extra_dbits,
      extra_base: 0,
      elems: D_CODES,
      max_length: MAX_BITS,
      max_code: 0,
    },
    bl_desc: {
      tree: bltree,
      stree: None,
      extra: extra_blbits,
      extra_base: 0,
      elems: BL_CODES,
      max_length: MAX_BL_BITS,
      max_code: 0,
    },
    bl_count: FixedArray::make(MAX_BITS + 1, 0),
    heap: FixedArray::make(2 * L_CODES + 1, 0),
    heap_len: 0,
    heap_max: 0,
    depth: FixedArray::make(2 * L_CODES + 1, 0),
    sym_buf: FixedArray::make(LIT_BUFSIZE * 3, 0),
    sym_next: 0,
    opt_len: 0L,
    static_len: 0L,
    bw: { out, bits: 0, count: 0, },
  }
  s.init_block()
  s
}

///|
fn Deflater::init_block(self : Deflater) -> Unit {
  for n in 0..<L_CODES {
    self.l_desc.tree.freq[n] = 0
  }
  for n in 0..<D_CODES {
    self.d_desc.tree.freq[n] = 0
  }
  for n in 0..<BL_CODES {
    self.bl_desc.tree.freq[n] = 0
  }
  self.l_desc.tree.freq[END_BLOCK] = 1
  self.opt_len = 0L
  self.static_len = 0L
  self.sym_next = 0
}

// ------------------------------------------------------------- deflate.c

///|
fn Deflater::update_hash(self : Deflater, c : Int) -> Unit {
  self.ins_h = ((self.ins_h << HASH_SHIFT) ^ c) & HASH_MASK
}

///|
/// INSERT_STRING: returns the previous head of the hash chain.
fn Deflater::insert_string(self : Deflater, str : Int) -> Int {
  self.update_hash(self.window[str + (MIN_MATCH - 1)])
  let h = self.head[self.ins_h]
  self.prev[str & WMASK] = h
  self.head[self.ins_h] = str
  h
}

///|
fn Deflater::slide_hash(self : Deflater) -> Unit {
  for n in 0..<HASH_SIZE {
    let m = self.head[n]
    self.head[n] = if m >= WSIZE { m - WSIZE } else { 0 }
  }
  for n in 0..<WSIZE {
    let m = self.prev[n]
    self.prev[n] = if m >= WSIZE { m - WSIZE } else { 0 }
  }
}

///|
fn Deflater::fill_window(self : Deflater) -> Unit {
  let window_size = 2 * WSIZE
  while true {
    let mut more = window_size - self.lookahead - self.strstart
    if self.strstart >= WSIZE + MAX_DIST {
      // memcpy(window, window + wsize, wsize - more)
      for k in 0..<(WSIZE - more) {
        self.window[k] = self.window[WSIZE + k]
      }
      self.match_start -= WSIZE
      self.strstart -= WSIZE
      self.block_start -= WSIZE
      if self.insert > self.strstart {
        self.insert = self.strstart
      }
      self.slide_hash()
      more += WSIZE
    }
    let avail = self.input.length() - self.next_in
    if avail == 0 {
      break
    }
    let n = if avail < more { avail } else { more }
    let dst = self.strstart + self.lookahead
    for k in 0..<n {
      self.window[dst + k] = self.input[self.next_in + k].to_int()
    }
    self.next_in += n
    self.lookahead += n
    if self.lookahead + self.insert >= MIN_MATCH {
      let mut str = self.strstart - self.insert
      self.ins_h = self.window[str]
      self.update_hash(self.window[str + 1])
      while self.insert > 0 {
        self.update_hash(self.window[str + MIN_MATCH - 1])
        self.prev[str & WMASK] = self.head[self.ins_h]
        self.head[self.ins_h] = str
        str += 1
        self.insert -= 1
        if self.lookahead + self.insert < MIN_MATCH {
          break
        }
      }
    }
    if !(self.lookahead < MIN_LOOKAHEAD &&
      self.input.length() - self.next_in != 0) {
      break
    }
  }
  // zero WIN_INIT bytes after the data (bytes longest_match may read)
  if self.high_water < window_size {
    let curr = self.strstart + self.lookahead
    if self.high_water < curr {
      let mut init = window_size - curr
      if init > WIN_INIT {
        init = WIN_INIT
      }
      for k in 0..<init {
        self.window[curr + k] = 0
      }
      self.high_water = curr + init
    } else if self.high_water < curr + WIN_INIT {
      let mut init = curr + WIN_INIT - self.high_water
      if init > window_size - self.high_water {
        init = window_size - self.high_water
      }
      for k in 0..<init {
        self.window[self.high_water + k] = 0
      }
      self.high_water += init
    }
  }
}

///|
fn Deflater::longest_match(self : Deflater, cur_match0 : Int) -> Int {
  let w = self.window
  let mut chain_length = MAX_CHAIN
  let strstart = self.strstart
  let mut best_len = self.prev_length
  let mut nice_match = NICE_MATCH
  let limit = if strstart > MAX_DIST { strstart - MAX_DIST } else { 0 }
  let strend = strstart + MAX_MATCH
  let mut scan_end1 = w[strstart + best_len - 1]
  let mut scan_end = w[strstart + best_len]
  if self.prev_length >= GOOD_MATCH {
    chain_length = chain_length >> 2
  }
  if nice_match > self.lookahead {
    nice_match = self.lookahead
  }
  let mut cur_match = cur_match0
  while true {
    let m = cur_match
    if !(w[m + best_len] != scan_end ||
      w[m + best_len - 1] != scan_end1 ||
      w[m] != w[strstart] ||
      w[m + 1] != w[strstart + 1]) {
      let mut scan = strstart + 2
      let mut mt = m + 2
      // compare until a mismatch or MAX_MATCH bytes
      while true {
        scan += 1
        mt += 1
        if !(w[scan] == w[mt] && scan < strend) {
          break
        }
      }
      if scan > strend {
        scan = strend
      }
      let len = MAX_MATCH - (strend - scan)
      if len > best_len {
        self.match_start = cur_match
        best_len = len
        if len >= nice_match {
          break
        }
        scan_end1 = w[strstart + best_len - 1]
        scan_end = w[strstart + best_len]
      }
    }
    cur_match = self.prev[cur_match & WMASK]
    if !(cur_match > limit) {
      break
    }
    chain_length -= 1
    if chain_length == 0 {
      break
    }
  }
  if best_len <= self.lookahead {
    best_len
  } else {
    self.lookahead
  }
}

///|
fn Deflater::tally_lit(self : Deflater, c : Int) -> Bool {
  self.sym_buf[self.sym_next] = 0
  self.sym_buf[self.sym_next + 1] = 0
  self.sym_buf[self.sym_next + 2] = c
  self.sym_next += 3
  self.l_desc.tree.freq[c] += 1
  self.sym_next == (LIT_BUFSIZE - 1) * 3
}

///|
fn Deflater::tally_dist(self : Deflater, dist0 : Int, len : Int) -> Bool {
  self.sym_buf[self.sym_next] = dist0 & 0xFF
  self.sym_buf[self.sym_next + 1] = (dist0 >> 8) & 0xFF
  self.sym_buf[self.sym_next + 2] = len
  self.sym_next += 3
  let dist = dist0 - 1
  self.l_desc.tree.freq[static_tables.length_code[len] + LITERALS + 1] += 1
  self.d_desc.tree.freq[d_code(dist)] += 1
  self.sym_next == (LIT_BUFSIZE - 1) * 3
}

///|
fn Deflater::flush_block(self : Deflater, last : Bool) -> Unit {
  let stored_len = self.strstart - self.block_start
  self.tr_flush_block(
    if self.block_start >= 0 {
      Some(self.block_start)
    } else {
      None
    },
    stored_len,
    last,
  )
  self.block_start = self.strstart
}

///|
/// deflate_slow with flush = Z_FINISH and all input available.
fn Deflater::deflate_slow(self : Deflater) -> Unit {
  while true {
    if self.lookahead < MIN_LOOKAHEAD {
      self.fill_window()
      if self.lookahead == 0 {
        break
      }
    }
    let mut hash_head = 0
    if self.lookahead >= MIN_MATCH {
      hash_head = self.insert_string(self.strstart)
    }
    self.prev_length = self.match_length
    self.prev_match = self.match_start
    self.match_length = MIN_MATCH - 1
    if hash_head != 0 &&
      self.prev_length < MAX_LAZY &&
      self.strstart - hash_head <= MAX_DIST {
      self.match_length = self.longest_match(hash_head)
      if self.match_length <= 5 &&
        self.match_length == MIN_MATCH &&
        self.strstart - self.match_start > TOO_FAR {
        self.match_length = MIN_MATCH - 1
      }
    }
    if self.prev_length >= MIN_MATCH && self.match_length <= self.prev_length {
      let max_insert = self.strstart + self.lookahead - MIN_MATCH
      let bflush = self.tally_dist(
        self.strstart - 1 - self.prev_match,
        self.prev_length - MIN_MATCH,
      )
      self.lookahead -= self.prev_length - 1
      self.prev_length -= 2
      while true {
        self.strstart += 1
        if self.strstart <= max_insert {
          ignore(self.insert_string(self.strstart))
        }
        self.prev_length -= 1
        if self.prev_length == 0 {
          break
        }
      }
      self.match_available = false
      self.match_length = MIN_MATCH - 1
      self.strstart += 1
      if bflush {
        self.flush_block(false)
      }
    } else if self.match_available {
      let bflush = self.tally_lit(self.window[self.strstart - 1])
      if bflush {
        self.flush_block(false)
      }
      self.strstart += 1
      self.lookahead -= 1
    } else {
      self.match_available = true
      self.strstart += 1
      self.lookahead -= 1
    }
  }
  if self.match_available {
    ignore(self.tally_lit(self.window[self.strstart - 1]))
    self.match_available = false
  }
  self.insert = if self.strstart < MIN_MATCH - 1 {
    self.strstart
  } else {
    MIN_MATCH - 1
  }
  self.flush_block(true)
}

// --------------------------------------------------------------- trees.c

///|
fn Deflater::smaller(self : Deflater, tree : Tree, n : Int, m : Int) -> Bool {
  tree.freq[n] < tree.freq[m] ||
  (tree.freq[n] == tree.freq[m] && self.depth[n] <= self.depth[m])
}

///|
fn Deflater::pqdownheap(self : Deflater, tree : Tree, k0 : Int) -> Unit {
  let mut k = k0
  let v = self.heap[k]
  let mut j = k << 1
  while j <= self.heap_len {
    if j < self.heap_len && self.smaller(tree, self.heap[j + 1], self.heap[j]) {
      j += 1
    }
    if self.smaller(tree, v, self.heap[j]) {
      break
    }
    self.heap[k] = self.heap[j]
    k = j
    j = j << 1
  }
  self.heap[k] = v
}

///|
fn Deflater::gen_bitlen(self : Deflater, desc : Desc) -> Unit {
  let tree = desc.tree
  let max_code = desc.max_code
  let extra = desc.extra
  let base = desc.extra_base
  let max_length = desc.max_length
  let mut overflow = 0
  for bits in 0..<=MAX_BITS {
    self.bl_count[bits] = 0
  }
  tree.len[self.heap[self.heap_max]] = 0
  let mut h = self.heap_max + 1
  while h < HEAP_SIZE {
    let n = self.heap[h]
    let mut bits = tree.len[tree.dad[n]] + 1
    if bits > max_length {
      bits = max_length
      overflow += 1
    }
    tree.len[n] = bits
    h += 1
    if n > max_code {
      continue
    }
    self.bl_count[bits] += 1
    let xbits = if n >= base { extra[n - base] } else { 0 }
    let f = tree.freq[n].to_int64()
    self.opt_len += f * (bits + xbits).to_int64()
    match desc.stree {
      Some(st) => self.static_len += f * (st.len[n] + xbits).to_int64()
      None => ()
    }
  }
  if overflow == 0 {
    return
  }
  while true {
    let mut bits = max_length - 1
    while self.bl_count[bits] == 0 {
      bits -= 1
    }
    self.bl_count[bits] -= 1
    self.bl_count[bits + 1] += 2
    self.bl_count[max_length] -= 1
    overflow -= 2
    if overflow <= 0 {
      break
    }
  }
  h = HEAP_SIZE
  let mut bits = max_length
  while bits != 0 {
    let mut n = self.bl_count[bits]
    while n != 0 {
      h -= 1
      let m = self.heap[h]
      if m > max_code {
        continue
      }
      if tree.len[m] != bits {
        self.opt_len += (bits - tree.len[m]).to_int64() *
          tree.freq[m].to_int64()
        tree.len[m] = bits
      }
      n -= 1
    }
    bits -= 1
  }
}

///|
fn Deflater::build_tree(self : Deflater, desc : Desc) -> Unit {
  let tree = desc.tree
  let elems = desc.elems
  let mut max_code = -1
  self.heap_len = 0
  self.heap_max = HEAP_SIZE
  for n in 0..<elems {
    if tree.freq[n] != 0 {
      self.heap_len += 1
      self.heap[self.heap_len] = n
      max_code = n
      self.depth[n] = 0
    } else {
      tree.len[n] = 0
    }
  }
  while self.heap_len < 2 {
    let node = if max_code < 2 {
      max_code += 1
      max_code
    } else {
      0
    }
    self.heap_len += 1
    self.heap[self.heap_len] = node
    tree.freq[node] = 1
    self.depth[node] = 0
    self.opt_len -= 1L
    match desc.stree {
      Some(st) => self.static_len -= st.len[node].to_int64()
      None => ()
    }
  }
  desc.max_code = max_code
  let mut n = self.heap_len / 2
  while n >= 1 {
    self.pqdownheap(tree, n)
    n -= 1
  }
  let mut node = elems
  while true {
    // pqremove
    let n = self.heap[1]
    self.heap[1] = self.heap[self.heap_len]
    self.heap_len -= 1
    self.pqdownheap(tree, 1)
    let m = self.heap[1]
    self.heap_max -= 1
    self.heap[self.heap_max] = n
    self.heap_max -= 1
    self.heap[self.heap_max] = m
    tree.freq[node] = tree.freq[n] + tree.freq[m]
    self.depth[node] = (if self.depth[n] >= self.depth[m] {
        self.depth[n]
      } else {
        self.depth[m]
      }) +
      1
    tree.dad[n] = node
    tree.dad[m] = node
    self.heap[1] = node
    node += 1
    self.pqdownheap(tree, 1)
    if self.heap_len < 2 {
      break
    }
  }
  self.heap_max -= 1
  self.heap[self.heap_max] = self.heap[1]
  self.gen_bitlen(desc)
  gen_codes(tree, max_code, self.bl_count)
}

///|
fn Deflater::scan_tree(self : Deflater, tree : Tree, max_code : Int) -> Unit {
  let bl = self.bl_desc.tree
  let mut prevlen = -1
  let mut nextlen = tree.len[0]
  let mut count = 0
  let mut max_count = 7
  let mut min_count = 4
  if nextlen == 0 {
    max_count = 138
    min_count = 3
  }
  tree.len[max_code + 1] = 0xFFFF
  for n in 0..<=max_code {
    let curlen = nextlen
    nextlen = tree.len[n + 1]
    count += 1
    if count < max_count && curlen == nextlen {
      continue
    } else if count < min_count {
      bl.freq[curlen] += count
    } else if curlen != 0 {
      if curlen != prevlen {
        bl.freq[curlen] += 1
      }
      bl.freq[REP_3_6] += 1
    } else if count <= 10 {
      bl.freq[REPZ_3_10] += 1
    } else {
      bl.freq[REPZ_11_138] += 1
    }
    count = 0
    prevlen = curlen
    if nextlen == 0 {
      max_count = 138
      min_count = 3
    } else if curlen == nextlen {
      max_count = 6
      min_count = 3
    } else {
      max_count = 7
      min_count = 4
    }
  }
}

///|
fn Deflater::send_code(self : Deflater, c : Int, tree : Tree) -> Unit {
  self.bw.send_bits(tree.code[c], tree.len[c])
}

///|
fn Deflater::send_tree(self : Deflater, tree : Tree, max_code : Int) -> Unit {
  let bl = self.bl_desc.tree
  let mut prevlen = -1
  let mut nextlen = tree.len[0]
  let mut count = 0
  let mut max_count = 7
  let mut min_count = 4
  if nextlen == 0 {
    max_count = 138
    min_count = 3
  }
  for n in 0..<=max_code {
    let curlen = nextlen
    nextlen = tree.len[n + 1]
    count += 1
    if count < max_count && curlen == nextlen {
      continue
    } else if count < min_count {
      while true {
        self.send_code(curlen, bl)
        count -= 1
        if count == 0 {
          break
        }
      }
    } else if curlen != 0 {
      if curlen != prevlen {
        self.send_code(curlen, bl)
        count -= 1
      }
      self.send_code(REP_3_6, bl)
      self.bw.send_bits(count - 3, 2)
    } else if count <= 10 {
      self.send_code(REPZ_3_10, bl)
      self.bw.send_bits(count - 3, 3)
    } else {
      self.send_code(REPZ_11_138, bl)
      self.bw.send_bits(count - 11, 7)
    }
    count = 0
    prevlen = curlen
    if nextlen == 0 {
      max_count = 138
      min_count = 3
    } else if curlen == nextlen {
      max_count = 6
      min_count = 3
    } else {
      max_count = 7
      min_count = 4
    }
  }
}

///|
fn Deflater::build_bl_tree(self : Deflater) -> Int {
  self.scan_tree(self.l_desc.tree, self.l_desc.max_code)
  self.scan_tree(self.d_desc.tree, self.d_desc.max_code)
  self.build_tree(self.bl_desc)
  let mut max_blindex = BL_CODES - 1
  while max_blindex >= 3 {
    if self.bl_desc.tree.len[bl_order[max_blindex]] != 0 {
      break
    }
    max_blindex -= 1
  }
  self.opt_len += (3 * (max_blindex + 1) + 5 + 5 + 4).to_int64()
  max_blindex
}

///|
fn Deflater::send_all_trees(
  self : Deflater,
  lcodes : Int,
  dcodes : Int,
  blcodes : Int,
) -> Unit {
  self.bw.send_bits(lcodes - 257, 5)
  self.bw.send_bits(dcodes - 1, 5)
  self.bw.send_bits(blcodes - 4, 4)
  for rank in 0..<blcodes {
    self.bw.send_bits(self.bl_desc.tree.len[bl_order[rank]], 3)
  }
  self.send_tree(self.l_desc.tree, lcodes - 1)
  self.send_tree(self.d_desc.tree, dcodes - 1)
}

///|
fn Deflater::compress_block(
  self : Deflater,
  ltree : Tree,
  dtree : Tree,
) -> Unit {
  let mut sx = 0
  while sx < self.sym_next {
    let mut dist = self.sym_buf[sx] | (self.sym_buf[sx + 1] << 8)
    let mut lc = self.sym_buf[sx + 2]
    sx += 3
    if dist == 0 {
      self.send_code(lc, ltree)
    } else {
      let mut code = static_tables.length_code[lc]
      self.send_code(code + LITERALS + 1, ltree)
      let mut extra = extra_lbits[code]
      if extra != 0 {
        lc -= static_tables.base_length[code]
        self.bw.send_bits(lc, extra)
      }
      dist -= 1
      code = d_code(dist)
      self.send_code(code, dtree)
      extra = extra_dbits[code]
      if extra != 0 {
        dist -= static_tables.base_dist[code]
        self.bw.send_bits(dist, extra)
      }
    }
  }
  self.send_code(END_BLOCK, ltree)
}

///|
fn Deflater::tr_flush_block(
  self : Deflater,
  buf : Int?,
  stored_len : Int,
  last : Bool,
) -> Unit {
  self.build_tree(self.l_desc)
  self.build_tree(self.d_desc)
  let max_blindex = self.build_bl_tree()
  let mut opt_lenb = (self.opt_len + 3L + 7L) >> 3
  let static_lenb = (self.static_len + 3L + 7L) >> 3
  if static_lenb <= opt_lenb {
    opt_lenb = static_lenb
  }
  let lastbit = if last { 1 } else { 0 }
  match buf {
    Some(start) if stored_len.to_int64() + 4L <= opt_lenb => {
      // _tr_stored_block
      self.bw.send_bits((0 << 1) + lastbit, 3)
      self.bw.windup()
      self.bw.out.write_byte((stored_len & 0xFF).to_byte())
      self.bw.out.write_byte(((stored_len >> 8) & 0xFF).to_byte())
      self.bw.out.write_byte((stored_len.lnot() & 0xFF).to_byte())
      self.bw.out.write_byte(((stored_len.lnot() >> 8) & 0xFF).to_byte())
      for k in 0..<stored_len {
        self.bw.out.write_byte(self.window[start + k].to_byte())
      }
    }
    _ =>
      if static_lenb == opt_lenb {
        self.bw.send_bits((1 << 1) + lastbit, 3)
        self.compress_block(static_tables.ltree, static_tables.dtree)
      } else {
        self.bw.send_bits((2 << 1) + lastbit, 3)
        self.send_all_trees(
          self.l_desc.max_code + 1,
          self.d_desc.max_code + 1,
          max_blindex + 1,
        )
        self.compress_block(self.l_desc.tree, self.d_desc.tree)
      }
  }
  self.init_block()
  if last {
    self.bw.windup()
  }
}

///|
/// Raw deflate of `data` exactly as zlib 1.3.1 deflate() at level 6.
pub fn deflate_raw(data : BytesView) -> Bytes {
  let out = @buffer.Buffer(size_hint=data.length() / 2 + 64)
  let s = Deflater::new(data, out)
  s.deflate_slow()
  out.to_bytes()
}

///|
/// COMPRESS: gzip member with SQL Server's header (`1F8B 08 00 00000000 04
/// 00`: no flags, no time, XFL 4, OS 0), zlib level-6 data, CRC-32 and size.
/// Empty input stays empty (captured).
pub fn gzip_compress(data : BytesView) -> Bytes {
  if data.length() == 0 {
    return b""
  }
  let out = @buffer.Buffer(size_hint=data.length() / 2 + 64)
  for b in [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0x04, 0] {
    out.write_byte(b.to_byte())
  }
  out.write_bytes(deflate_raw(data))
  let crc = crc32(data)
  let size = data.length()
  for k in 0..<4 {
    out.write_byte((crc >> (8 * k)).to_byte())
  }
  for k in 0..<4 {
    out.write_byte((size >> (8 * k)).to_byte())
  }
  out.to_bytes()
}
