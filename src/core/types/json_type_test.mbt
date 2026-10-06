// The json data type: normalization and conversions (expected values from
// harness/corpus/json4/type-cast captures).

///|
fn jt(text : String) -> String {
  @types.json_type_normalize(text) catch {
    e => "\{e.number()}/\{e.state()} \{e.message()}"
  }
}

///|
test "json type normalizes whitespace, numbers and duplicate members" {
  assert_eq(
    jt("{ \"a\" : 1, \"b\":[1, 2 ,{\"c\":null}] }"),
    "{\"a\":1,\"b\":[1,2,{\"c\":null}]}",
  )
  assert_eq(
    jt("[1.50, 1e2, -0, -0.0, 0.00, 1e-11, 1e28]"),
    "[1.50,100.0000000000,0,0.0,0.00,0.0000000000,9999999999999999583119736832.0000000000]",
  )
  assert_eq(
    jt("{\"a\":1,\"b\":2,\"a\":3,\"A\":4}"),
    "{\"a\":1,\"b\":2,\"A\":4}",
  )
  assert_eq(jt("[10.1234567890123456789012345678901234567]"), "[10.1234567890]")
}

///|
test "json type errors report UTF-8 byte positions" {
  assert_eq(
    jt("[\"é\", x]"),
    "13609/9 JSON text is not properly formatted. Unexpected character 'x' is found at position 7.",
  )
  assert_eq(
    jt("1"),
    "13609/9 JSON text is not properly formatted. Unexpected character '1' is found at position 0.",
  )
  assert_eq(
    jt("[1, {\"a\":1,}]"),
    "13609/9 JSON text is not properly formatted. Unexpected character '}' is found at position 11.",
  )
  assert_eq(
    jt("[1e29]"),
    "1007/5 The number '1e29' is out of the range for numeric representation (maximum precision 38).",
  )
  assert_eq(
    jt("[999999999999999999999999999999999999999]"),
    "1007/3 The number '999999999999999999999999999999999999999' is out of the range for numeric representation (maximum precision 38).",
  )
}

///|
test "json type to text checks size and code page" {
  let t = @types.NVarChar(Some(6), @types.default_collation)
  assert_eq(
    outcome(() => {
      @types.cast(NativeJson(@types.JsonData::parse("{\"a\":1}")), Json, t)
    }),
    "13639/1 Target string size is too small to represent the JSON instance.",
  )
  assert_eq(
    outcome(() => {
      @types.cast(
        NativeJson(@types.JsonData::parse("{\"a\":\"\u{100}\"}")),
        Json,
        VarChar(Some(30), @types.default_collation),
      )
    }),
    "ok '{\"a\":\"A\"}'",
  )
}
