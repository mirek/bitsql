// Inflate (RFC 1951) and DECOMPRESS's reading of a gzip member (RFC 1952).
//
// DECOMPRESS outcomes, captured (msduck compress-decompress #052-#065,
// harness/corpus/conversion/decompress.cases.json):
//
// - empty input: empty output;
// - input that ends inside the header or the deflate data: NULL;
// - a first byte other than 0x1F, a second other than 0x8B, a method
//   other than 8, an invalid deflate stream: error 9826;
// - FEXTRA/FNAME/FCOMMENT are skipped, FHCRC is skipped unchecked,
//   reserved flag bits are ignored;
// - the trailer is checked only when all 8 bytes are present (wrong CRC-32
//   or ISIZE: 9826); a short trailer is ignored;
// - bytes after the member (garbage or a second member) are ignored;
// - an empty result from a non-empty member is NULL.

///|
/// Result of reading a gzip member.
pub(all) enum Decompressed {
  /// the data (possibly empty only for empty input)
  Data(Bytes)
  /// the input ended early, or the member holds no data: SQL NULL
  Incomplete
  /// corrupted input: 9826
  Corrupt
}

///|
priv suberror InflateError {
  NeedInput
  Bad
}

///|
priv struct BitReader {
  data : BytesView
  mut pos : Int
  mut bits : Int
  mut count : Int
}

///|
fn BitReader::need(self : BitReader, n : Int) -> Unit raise InflateError {
  while self.count < n {
    if self.pos >= self.data.length() {
      raise NeedInput
    }
    self.bits = self.bits | (self.data[self.pos].to_int() << self.count)
    self.pos += 1
    self.count += 8
  }
}

///|
fn BitReader::take(self : BitReader, n : Int) -> Int raise InflateError {
  if n == 0 {
    return 0
  }
  self.need(n)
  let v = self.bits & ((1 << n) - 1)
  self.bits = self.bits >> n
  self.count -= n
  v
}

///|
/// Canonical Huffman decoding table (puff.c style).
priv struct Huffman {
  count : FixedArray[Int]
  symbol : FixedArray[Int]
}

///|
fn Huffman::build(lengths : ArrayView[Int]) -> Huffman raise InflateError {
  let count = FixedArray::make(16, 0)
  for l in lengths {
    count[l] += 1
  }
  if count[0] == lengths.length() {
    // no codes: decoding anything is an error, building is fine
    return { count, symbol: FixedArray::make(lengths.length(), 0), }
  }
  let mut left = 1
  for len in 1..<16 {
    left = left << 1
    left -= count[len]
    if left < 0 {
      raise Bad // over-subscribed
    }
  }
  let offs = FixedArray::make(16, 0)
  for len in 1..<15 {
    offs[len + 1] = offs[len] + count[len]
  }
  let symbol = FixedArray::make(lengths.length(), 0)
  for sym, l in lengths {
    if l != 0 {
      symbol[offs[l]] = sym
      offs[l] += 1
    }
  }
  { count, symbol, }
}

///|
fn BitReader::decode(self : BitReader, h : Huffman) -> Int raise InflateError {
  let mut code = 0
  let mut first = 0
  let mut index = 0
  for len in 1..<16 {
    code = code | self.take(1)
    let count = h.count[len]
    if code - count < first {
      return h.symbol[index + (code - first)]
    }
    index += count
    first += count
    first = first << 1
    code = code << 1
  }
  raise Bad
}

///|
let length_base : FixedArray[Int] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
let length_extra : FixedArray[Int] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
let dist_base : FixedArray[Int] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let dist_extra : FixedArray[Int] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
fn inflate_codes(
  br : BitReader,
  out : Array[Byte],
  lit : Huffman,
  dist : Huffman,
) -> Unit raise InflateError {
  while true {
    let sym = br.decode(lit)
    if sym < 256 {
      out.push(sym.to_byte())
    } else if sym == 256 {
      return
    } else {
      let s = sym - 257
      if s >= 29 {
        raise Bad
      }
      let len = length_base[s] + br.take(length_extra[s])
      let ds = br.decode(dist)
      if ds >= 30 {
        raise Bad
      }
      let d = dist_base[ds] + br.take(dist_extra[ds])
      if d > out.length() {
        raise Bad
      }
      let start = out.length() - d
      for k in 0..<len {
        out.push(out[start + k])
      }
    }
  }
}

///|
let fixed_tables : (Huffman, Huffman) = {
  let l = FixedArray::make(288, 0)
  for i in 0..<288 {
    l[i] = if i < 144 {
      8
    } else if i < 256 {
      9
    } else if i < 280 {
      7
    } else {
      8
    }
  }
  let d = FixedArray::make(30, 5)
  (
    Huffman::build(l[:]) catch {
      _ => panic()
    },
    Huffman::build(d[:]) catch {
      _ => panic()
    },
  )
}

///|
/// Inflates a raw deflate stream starting at `br`; stops after the final
/// block (the reader then sits on the next byte boundary).
fn inflate_stream(br : BitReader) -> Bytes raise InflateError {
  let out : Array[Byte] = []
  while true {
    let last = br.take(1)
    let btype = br.take(2)
    match btype {
      0 => {
        br.bits = 0
        br.count = 0
        if br.pos + 4 > br.data.length() {
          raise NeedInput
        }
        let len = br.data[br.pos].to_int() | (br.data[br.pos + 1].to_int() << 8)
        let nlen = br.data[br.pos + 2].to_int() |
          (br.data[br.pos + 3].to_int() << 8)
        if len != (nlen.lnot() & 0xFFFF) {
          raise Bad
        }
        br.pos += 4
        if br.pos + len > br.data.length() {
          raise NeedInput
        }
        for k in 0..<len {
          out.push(br.data[br.pos + k])
        }
        br.pos += len
      }
      1 => inflate_codes(br, out, fixed_tables.0, fixed_tables.1)
      2 => {
        let nlen = br.take(5) + 257
        let ndist = br.take(5) + 1
        let ncode = br.take(4) + 4
        if nlen > 286 || ndist > 30 {
          raise Bad
        }
        let order = [
          16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
        ]
        let cl = FixedArray::make(19, 0)
        for i in 0..<ncode {
          cl[order[i]] = br.take(3)
        }
        let lencode = Huffman::build(cl[:])
        let lengths = FixedArray::make(nlen + ndist, 0)
        let mut i = 0
        while i < nlen + ndist {
          let sym = br.decode(lencode)
          if sym < 16 {
            lengths[i] = sym
            i += 1
          } else {
            let (value, rep) = match sym {
              16 => {
                if i == 0 {
                  raise Bad
                }
                (lengths[i - 1], 3 + br.take(2))
              }
              17 => (0, 3 + br.take(3))
              _ => (0, 11 + br.take(7))
            }
            if i + rep > nlen + ndist {
              raise Bad
            }
            for _ in 0..<rep {
              lengths[i] = value
              i += 1
            }
          }
        }
        if lengths[256] == 0 {
          raise Bad
        }
        let lit = Huffman::build(lengths[0:nlen])
        let dist = Huffman::build(lengths[nlen:nlen + ndist])
        inflate_codes(br, out, lit, dist)
      }
      _ => raise Bad
    }
    if last == 1 {
      break
    }
  }
  Bytes::from_array(out[:])
}

///|
/// DECOMPRESS of a gzip member (rules above).
pub fn gzip_decompress(data : BytesView) -> Decompressed {
  let n = data.length()
  if n == 0 {
    return Data(b"")
  }
  if data[0] != b'\x1F' {
    return Corrupt
  }
  if n < 2 {
    return Incomplete
  }
  if data[1] != b'\x8B' {
    return Corrupt
  }
  if n < 3 {
    return Incomplete
  }
  if data[2] != b'\x08' {
    return Corrupt
  }
  if n < 10 {
    return Incomplete
  }
  let flg = data[3].to_int()
  let mut pos = 10
  if (flg & 4) != 0 {
    if pos + 2 > n {
      return Incomplete
    }
    pos += 2 + (data[pos].to_int() | (data[pos + 1].to_int() << 8))
  }
  for bit in [8, 16] {
    if (flg & bit) != 0 {
      while pos < n && data[pos] != b'\x00' {
        pos += 1
      }
      pos += 1
    }
  }
  if (flg & 2) != 0 {
    pos += 2
  }
  if pos >= n {
    return Incomplete
  }
  let br : BitReader = { data, pos, bits: 0, count: 0, }
  let out = inflate_stream(br) catch {
    NeedInput => return Incomplete
    Bad => return Corrupt
  }
  // the trailer starts at the next byte boundary
  let t = br.pos
  if t + 8 <= n {
    let crc = data[t].to_uint() |
      (data[t + 1].to_uint() << 8) |
      (data[t + 2].to_uint() << 16) |
      (data[t + 3].to_uint() << 24)
    let size = data[t + 4].to_uint() |
      (data[t + 5].to_uint() << 8) |
      (data[t + 6].to_uint() << 16) |
      (data[t + 7].to_uint() << 24)
    if crc != crc32(out[:]) || size != out.length().reinterpret_as_uint() {
      return Corrupt
    }
  }
  if out.length() == 0 {
    Incomplete
  } else {
    Data(out)
  }
}
