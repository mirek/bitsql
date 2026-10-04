///|
// Advanced path accessors and path syntax, expected values captured from
// SQL Server 2025 (msduck json-advanced-path, json-extraction-wildcard;
// harness/corpus/json3).
fn show(f : () -> String? raise @json.JsonError) -> String {
  try f() catch {
    @json.JsonError(n, st, m) => "E\{n}/\{st} \{m}"
  } noraise {
    Some(s) => "=" + s
    None => "NULL"
  }
}

///|
test "multi-value accessors" {
  let v = (d : String, p : String) => show(() => @json.json_value(d, p))
  let q = (d : String, p : String) => show(() => @json.json_query(d, path=p))
  assert_eq(v("[1,2,3]", "$[2 to 9]"), "=3")
  assert_eq(v("[1,2,3]", "$[0 to 1]"), "NULL")
  assert_eq(v("[1,x]", "$[0 to 0]"), "=1")
  assert_eq(
    v("[1,2,x]", "$[0 to 1]"),
    "E13609/1 JSON text is not properly formatted. Unexpected character 'x' is found at position 5.",
  )
  assert_eq(v("{\"a\":[1,2],\"b\":x}", "$.a[0 to 1]"), "NULL")
  assert_eq(v("[1,null,x]", "$[*]"), "NULL")
  assert_eq(v("[{\"b\":0},{\"a\":2}]", "strict $[*].a"), "=2")
  assert_eq(
    v("[1]", "strict $[0 to 2]"),
    "E13659/1 Index 0 provided at position 3 is not within the array of size 2.",
  )
  assert_eq(
    v("[1,2]", "strict $[*]"),
    "E13608/1 Property cannot be found on the specified JSON path.",
  )
  assert_eq(
    q("[1,2]", "strict $[*]"),
    "E13624/3 Object or array cannot be found in the specified JSON path.",
  )
  assert_eq(q("[{\"x\":1}]", "strict $[*]"), "={\"x\":1}")
  assert_eq(v("{\"x\":{\"a\":1},\"y\":[2]}", "$.*[0]"), "=2")
  assert_eq(q("[null]", "strict $[0]"), "NULL")
}

///|
test "path syntax errors" {
  let v = (p : String) => show(() => @json.json_value("[1,2]", p))
  let msg = (st : Int, c : String, pos : Int) => {
    "E13607/\{st} JSON path is not properly formatted. Unexpected character '\{c}' is found at position \{pos}."
  }
  assert_eq(v("$[0TO 0]"), msg(15, "T", 3))
  assert_eq(v("$[0 TO 0]"), msg(21, "T", 4))
  assert_eq(v("$[0 to 999999999999999999999]"), msg(16, "9", 17))
  assert_eq(v("$[4294967297]"), msg(16, "7", 11))
  assert_eq(v("$[9999999999]"), "NULL")
  assert_eq(v("$.a b"), msg(22, "b", 4))
  assert_eq(v("$.a 1"), msg(14, "1", 4))
  assert_eq(v("$.*x"), msg(14, "x", 3))
  assert_eq(v("$.\"a"), msg(20, ".", 4))
  assert_eq(v("strict x"), msg(22, "x", 7))
  assert_eq(v(""), msg(14, ".", 0))
  assert_eq(v(" $ [ 1 ] "), "=2")
  assert_eq(
    v("$[last,0]"),
    "E13660/2 Last operator not yet supported for advanced JSON array accessors.",
  )
  assert_eq(
    v("$[0,last]"),
    "E13660/5 Comma operator not yet supported for advanced JSON array accessors.",
  )
  assert_eq(
    v("$[2 to 1"),
    "E13660/1 Reversed indexing not yet supported for advanced JSON array accessors.",
  )
}

///|
test "lob states, path exists, depth" {
  assert_eq(
    show(() => @json.json_value("1", "$", lob=true)),
    "E13609/2 JSON text is not properly formatted. Unexpected character '.' is found at position 1.",
  )
  assert_eq(@json.json_path_exists("{\"a\":1,\"b\":x}", "$.a"), 0)
  assert_eq(@json.json_path_exists("{\"a\":null}", "$.a"), 1)
  assert_eq(@json.isjson("[".repeat(129) + "\"a"), 0)
  let deep = @json.isjson("[".repeat(128) + "{\"a\"") catch {
    @json.JsonError(n, _, _) => n
  }
  assert_eq(deep, 13606)
}
