// Pure MoonBit message digests for HASHBYTES: MD4 (RFC 1320), MD5
// (RFC 1321), SHA-1, SHA-256 and SHA-512 (FIPS 180-4).

///|
fn rotl32(x : UInt, n : Int) -> UInt {
  (x << n) | (x >> (32 - n))
}

///|
fn rotr32(x : UInt, n : Int) -> UInt {
  (x >> n) | (x << (32 - n))
}

///|
fn rotr64(x : UInt64, n : Int) -> UInt64 {
  (x >> n) | (x << (64 - n))
}

///|
/// Message padding: 0x80, zeros, then the bit length (`len_bytes` wide,
/// little- or big-endian) so the total is a multiple of `block`.
fn md_pad(
  msg : Bytes,
  block : Int,
  len_bytes : Int,
  big_endian : Bool,
) -> Array[Byte] {
  let out = msg.to_array()
  let bits = msg.length().to_uint64() * 8UL
  out.push(b'\x80')
  while (out.length() + len_bytes) % block != 0 {
    out.push(b'\x00')
  }
  for i in 0..<len_bytes {
    let shift = if big_endian { (len_bytes - 1 - i) * 8 } else { i * 8 }
    let byte = if shift >= 64 { 0UL } else { (bits >> shift) & 0xFFUL }
    out.push(byte.to_byte())
  }
  out
}

///|
fn le32(a : Array[Byte], i : Int) -> UInt {
  a[i].to_uint() |
  (a[i + 1].to_uint() << 8) |
  (a[i + 2].to_uint() << 16) |
  (a[i + 3].to_uint() << 24)
}

///|
fn be32(a : Array[Byte], i : Int) -> UInt {
  (a[i].to_uint() << 24) |
  (a[i + 1].to_uint() << 16) |
  (a[i + 2].to_uint() << 8) |
  a[i + 3].to_uint()
}

///|
fn be64(a : Array[Byte], i : Int) -> UInt64 {
  let mut x = 0UL
  for k in 0..<8 {
    x = (x << 8) | a[i + k].to_uint64()
  }
  x
}

///|
fn words_le(ws : Array[UInt]) -> Bytes {
  Bytes::makei(ws.length() * 4, i => (ws[i / 4] >> (8 * (i % 4))).to_byte())
}

///|
fn words_be(ws : Array[UInt]) -> Bytes {
  Bytes::makei(ws.length() * 4, i => (ws[i / 4] >> (8 * (3 - i % 4))).to_byte())
}

///|
let md5_s : Array[Int] = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9,
  14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
]

///|
let md5_k : Array[UInt] = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
  0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
  0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
  0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
  0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
  0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
  0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
  0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
  0xeb86d391,
]

///|
fn md5(msg : Bytes) -> Bytes {
  let m = md_pad(msg, 64, 8, false)
  let h = [0x67452301U, 0xefcdab89U, 0x98badcfeU, 0x10325476U]
  for off = 0; off < m.length(); off = off + 64 {
    let w = Array::makei(16, i => le32(m, off + i * 4))
    let mut a = h[0]
    let mut b = h[1]
    let mut c = h[2]
    let mut d = h[3]
    for i in 0..<64 {
      let (f, g) = if i < 16 {
        ((b & c) | (b.lnot() & d), i)
      } else if i < 32 {
        ((d & b) | (d.lnot() & c), (5 * i + 1) % 16)
      } else if i < 48 {
        (b ^ c ^ d, (3 * i + 5) % 16)
      } else {
        (c ^ (b | d.lnot()), 7 * i % 16)
      }
      let tmp = d
      d = c
      c = b
      b = b + rotl32(a + f + md5_k[i] + w[g], md5_s[i])
      a = tmp
    }
    h[0] = h[0] + a
    h[1] = h[1] + b
    h[2] = h[2] + c
    h[3] = h[3] + d
  }
  words_le(h)
}

///|
fn md4(msg : Bytes) -> Bytes {
  let m = md_pad(msg, 64, 8, false)
  let h = [0x67452301U, 0xefcdab89U, 0x98badcfeU, 0x10325476U]
  for off = 0; off < m.length(); off = off + 64 {
    let x = Array::makei(16, i => le32(m, off + i * 4))
    let mut a = h[0]
    let mut b = h[1]
    let mut c = h[2]
    let mut d = h[3]
    let ff = (x : UInt, y : UInt, z : UInt) => (x & y) | (x.lnot() & z)
    let gg = (x : UInt, y : UInt, z : UInt) => (x & y) | (x & z) | (y & z)
    let hh = (x : UInt, y : UInt, z : UInt) => x ^ y ^ z
    let r1 = [3, 7, 11, 19]
    for i in 0..<16 {
      let t = rotl32(a + ff(b, c, d) + x[i], r1[i % 4])
      a = d
      d = c
      c = b
      b = t
    }
    let r2 = [3, 5, 9, 13]
    let order2 = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]
    for i in 0..<16 {
      let t = rotl32(a + gg(b, c, d) + x[order2[i]] + 0x5a827999U, r2[i % 4])
      a = d
      d = c
      c = b
      b = t
    }
    let r3 = [3, 9, 11, 15]
    let order3 = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
    for i in 0..<16 {
      let t = rotl32(a + hh(b, c, d) + x[order3[i]] + 0x6ed9eba1U, r3[i % 4])
      a = d
      d = c
      c = b
      b = t
    }
    h[0] = h[0] + a
    h[1] = h[1] + b
    h[2] = h[2] + c
    h[3] = h[3] + d
  }
  words_le(h)
}

///|
fn sha1(msg : Bytes) -> Bytes {
  let m = md_pad(msg, 64, 8, true)
  let h = [0x67452301U, 0xEFCDAB89U, 0x98BADCFEU, 0x10325476U, 0xC3D2E1F0U]
  for off = 0; off < m.length(); off = off + 64 {
    let w : Array[UInt] = Array::make(80, 0U)
    for i in 0..<16 {
      w[i] = be32(m, off + i * 4)
    }
    for i in 16..<80 {
      w[i] = rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
    }
    let mut a = h[0]
    let mut b = h[1]
    let mut c = h[2]
    let mut d = h[3]
    let mut e = h[4]
    for i in 0..<80 {
      let (f, k) = if i < 20 {
        ((b & c) | (b.lnot() & d), 0x5A827999U)
      } else if i < 40 {
        (b ^ c ^ d, 0x6ED9EBA1U)
      } else if i < 60 {
        ((b & c) | (b & d) | (c & d), 0x8F1BBCDCU)
      } else {
        (b ^ c ^ d, 0xCA62C1D6U)
      }
      let t = rotl32(a, 5) + f + e + k + w[i]
      e = d
      d = c
      c = rotl32(b, 30)
      b = a
      a = t
    }
    h[0] = h[0] + a
    h[1] = h[1] + b
    h[2] = h[2] + c
    h[3] = h[3] + d
    h[4] = h[4] + e
  }
  words_be(h)
}

///|
let sha256_k : Array[UInt] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
  0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
  0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
  0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
  0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
  0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
  0xc67178f2,
]

///|
fn sha256(msg : Bytes) -> Bytes {
  let m = md_pad(msg, 64, 8, true)
  let h = [
    0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU, 0x510e527fU, 0x9b05688cU,
    0x1f83d9abU, 0x5be0cd19U,
  ]
  for off = 0; off < m.length(); off = off + 64 {
    let w : Array[UInt] = Array::make(64, 0U)
    for i in 0..<16 {
      w[i] = be32(m, off + i * 4)
    }
    for i in 16..<64 {
      let s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3)
      let s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    }
    let v = h.copy()
    for i in 0..<64 {
      let s1 = rotr32(v[4], 6) ^ rotr32(v[4], 11) ^ rotr32(v[4], 25)
      let ch = (v[4] & v[5]) ^ (v[4].lnot() & v[6])
      let t1 = v[7] + s1 + ch + sha256_k[i] + w[i]
      let s0 = rotr32(v[0], 2) ^ rotr32(v[0], 13) ^ rotr32(v[0], 22)
      let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
      let t2 = s0 + maj
      v[7] = v[6]
      v[6] = v[5]
      v[5] = v[4]
      v[4] = v[3] + t1
      v[3] = v[2]
      v[2] = v[1]
      v[1] = v[0]
      v[0] = t1 + t2
    }
    for i in 0..<8 {
      h[i] = h[i] + v[i]
    }
  }
  words_be(h)
}

///|
let sha512_k : Array[UInt64] = [
  0x428a2f98d728ae22UL, 0x7137449123ef65cdUL, 0xb5c0fbcfec4d3b2fUL, 0xe9b5dba58189dbbcUL,
  0x3956c25bf348b538UL, 0x59f111f1b605d019UL, 0x923f82a4af194f9bUL, 0xab1c5ed5da6d8118UL,
  0xd807aa98a3030242UL, 0x12835b0145706fbeUL, 0x243185be4ee4b28cUL, 0x550c7dc3d5ffb4e2UL,
  0x72be5d74f27b896fUL, 0x80deb1fe3b1696b1UL, 0x9bdc06a725c71235UL, 0xc19bf174cf692694UL,
  0xe49b69c19ef14ad2UL, 0xefbe4786384f25e3UL, 0x0fc19dc68b8cd5b5UL, 0x240ca1cc77ac9c65UL,
  0x2de92c6f592b0275UL, 0x4a7484aa6ea6e483UL, 0x5cb0a9dcbd41fbd4UL, 0x76f988da831153b5UL,
  0x983e5152ee66dfabUL, 0xa831c66d2db43210UL, 0xb00327c898fb213fUL, 0xbf597fc7beef0ee4UL,
  0xc6e00bf33da88fc2UL, 0xd5a79147930aa725UL, 0x06ca6351e003826fUL, 0x142929670a0e6e70UL,
  0x27b70a8546d22ffcUL, 0x2e1b21385c26c926UL, 0x4d2c6dfc5ac42aedUL, 0x53380d139d95b3dfUL,
  0x650a73548baf63deUL, 0x766a0abb3c77b2a8UL, 0x81c2c92e47edaee6UL, 0x92722c851482353bUL,
  0xa2bfe8a14cf10364UL, 0xa81a664bbc423001UL, 0xc24b8b70d0f89791UL, 0xc76c51a30654be30UL,
  0xd192e819d6ef5218UL, 0xd69906245565a910UL, 0xf40e35855771202aUL, 0x106aa07032bbd1b8UL,
  0x19a4c116b8d2d0c8UL, 0x1e376c085141ab53UL, 0x2748774cdf8eeb99UL, 0x34b0bcb5e19b48a8UL,
  0x391c0cb3c5c95a63UL, 0x4ed8aa4ae3418acbUL, 0x5b9cca4f7763e373UL, 0x682e6ff3d6b2b8a3UL,
  0x748f82ee5defb2fcUL, 0x78a5636f43172f60UL, 0x84c87814a1f0ab72UL, 0x8cc702081a6439ecUL,
  0x90befffa23631e28UL, 0xa4506cebde82bde9UL, 0xbef9a3f7b2c67915UL, 0xc67178f2e372532bUL,
  0xca273eceea26619cUL, 0xd186b8c721c0c207UL, 0xeada7dd6cde0eb1eUL, 0xf57d4f7fee6ed178UL,
  0x06f067aa72176fbaUL, 0x0a637dc5a2c898a6UL, 0x113f9804bef90daeUL, 0x1b710b35131c471bUL,
  0x28db77f523047d84UL, 0x32caab7b40c72493UL, 0x3c9ebe0a15c9bebcUL, 0x431d67c49c100d4cUL,
  0x4cc5d4becb3e42b6UL, 0x597f299cfc657e2aUL, 0x5fcb6fab3ad6faecUL, 0x6c44198c4a475817UL,
]

///|
fn sha512(msg : Bytes) -> Bytes {
  let m = md_pad(msg, 128, 16, true)
  let h = [
    0x6a09e667f3bcc908UL, 0xbb67ae8584caa73bUL, 0x3c6ef372fe94f82bUL, 0xa54ff53a5f1d36f1UL,
    0x510e527fade682d1UL, 0x9b05688c2b3e6c1fUL, 0x1f83d9abfb41bd6bUL, 0x5be0cd19137e2179UL,
  ]
  for off = 0; off < m.length(); off = off + 128 {
    let w : Array[UInt64] = Array::make(80, 0UL)
    for i in 0..<16 {
      w[i] = be64(m, off + i * 8)
    }
    for i in 16..<80 {
      let s0 = rotr64(w[i - 15], 1) ^ rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7)
      let s1 = rotr64(w[i - 2], 19) ^ rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    }
    let v = h.copy()
    for i in 0..<80 {
      let s1 = rotr64(v[4], 14) ^ rotr64(v[4], 18) ^ rotr64(v[4], 41)
      let ch = (v[4] & v[5]) ^ (v[4].lnot() & v[6])
      let t1 = v[7] + s1 + ch + sha512_k[i] + w[i]
      let s0 = rotr64(v[0], 28) ^ rotr64(v[0], 34) ^ rotr64(v[0], 39)
      let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
      let t2 = s0 + maj
      v[7] = v[6]
      v[6] = v[5]
      v[5] = v[4]
      v[4] = v[3] + t1
      v[3] = v[2]
      v[2] = v[1]
      v[1] = v[0]
      v[0] = t1 + t2
    }
    for i in 0..<8 {
      h[i] = h[i] + v[i]
    }
  }
  Bytes::makei(64, i => (h[i / 8] >> (8 * (7 - i % 8))).to_byte())
}
