// Focused tests for the built-in function helpers. Expected values are
// SQL Server captures (harness/corpus/functions) or standard test vectors.

///|
fn hex(b : Bytes) -> String {
  let out = StringBuilder()
  for x in b {
    let h = x.to_int().to_string(radix=16)
    if h.length() < 2 {
      out.write_char('0')
    }
    out.write_string(h)
  }
  out.to_string()
}

///|
test "digests match HASHBYTES captures" {
  let abc = b"abc"
  inspect(hex(md4(abc)), content="a448017aaf21d8525fc10ae87aa6729d")
  inspect(hex(md5(abc)), content="900150983cd24fb0d6963f7d28e17f72")
  inspect(hex(sha1(abc)), content="a9993e364706816aba3e25717850c26c9cd0d89d")
  inspect(
    hex(sha256(abc)),
    content="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  inspect(
    hex(sha512(b"")),
    content="cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
  )
  inspect(hex(md5(b"")), content="d41d8cd98f00b204e9800998ecf8427e")
}

///|
test "RAND reproduces SQL Server's sequence" {
  let rt = Runtime::new(database="master", spid=51, now=0L, seed=1L)
  rand_seed(rt, 7L)
  inspect(rand_next(rt), content="0.7137037910404728")
  inspect(rand_next(rt), content="0.9457197353968156")
  inspect(rand_next(rt), content="0.7057602239353887")
  rand_seed(rt, 0L)
  inspect(rand_next(rt), content="0.9435973904241444")
}

///|
test "SOUNDEX and DIFFERENCE" {
  inspect(soundex("Ashcraft"), content="A226")
  inspect(soundex("Pfister"), content="P236")
  inspect(soundex("ab-c"), content="A100")
  inspect(soundex(" abc"), content="0000")
  inspect(difference("Washington", "Washer"), content="3")
  inspect(difference("Washer", "Washington"), content="2")
  inspect(difference("Pfister", "Fister"), content="2")
  inspect(difference("abc", "xyz"), content="2")
}

///|
test "STR formatting" {
  inspect(str_format(1.5, 10L, 20L).unwrap_or("NULL"), content="1.50000000")
  inspect(str_format(99.99, 4L, 1L).unwrap_or("NULL"), content="****")
  inspect(str_format(9.96, 4L, 1L).unwrap_or("NULL"), content="10.0")
  inspect(str_format(-0.4, 10L, 0L).unwrap_or("NULL"), content="        -0")
  inspect(str_format(12.0, 0L, 0L).unwrap_or("NULL"), content="NULL")
}

///|
test "ISNUMERIC text rules" {
  let cases = [
    "123", "$12", "-", "1,000", "1e", "- 5", "5-", "1E+309", "1d2", "0x10",
  ]
  inspect(
    cases.map(s => if isnumeric_text(s) { "1" } else { "0" }).join(""),
    content="1111010010",
  )
}

///|
test "calendar helpers" {
  // 2024-12-29 is a Sunday in week 53, ISO week 52
  let d = @types.days_from_civil(2024, 12, 29)
  inspect(week_of_year(d, 7), content="53")
  inspect(iso_week(d), content="52")
  inspect(weekday_index(d), content="0")
  let jan31 = @types.days_from_civil(2024, 1, 31)
  let (y, m, d) = @types.civil_from_days(add_months(jan31, 1L).unwrap())
  inspect("\{y}-\{m}-\{d}", content="2024-2-29")
}
