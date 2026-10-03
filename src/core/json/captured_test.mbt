///|
// Generated from msduck reference/json-extraction-boundaries.json (SQL Server
// 2025 captures). Regenerate rather than edit; see .claude/skills/harness.
fn check(
  f : String,
  doc : String,
  path : String,
  expected : String,
) -> Unit raise {
  let got = try {
    let v = if f == "JSON_VALUE" {
      @json.json_value(doc, path)
    } else {
      @json.json_query(doc, path~)
    }
    match v {
      None => "NULL"
      Some(s) => "=" + s
    }
  } catch {
    @json.JsonError(n, st, m) => "E\{n}/\{st} \{m}"
  }
  assert_eq(got, expected, msg="\{f}(\{doc}, \{path})")
}

///|
test "captured JSON_VALUE / JSON_QUERY boundaries" {
  check("JSON_VALUE", "{\"a\":1}", "$.a", "=1")
  check("JSON_QUERY", "{\"a\":1}", "$.a", "NULL")
  check("JSON_VALUE", "{\"a\":{\"x\":1}}", "$.a", "NULL")
  check("JSON_QUERY", "{\"a\":{\"x\":1}}", "$.a", "={\"x\":1}")
  check("JSON_VALUE", "{\"a\":[1,2]}", "$.a", "NULL")
  check("JSON_QUERY", "{\"a\":[1,2]}", "$.a", "=[1,2]")
  check("JSON_VALUE", "{\"a\":1}", "$", "NULL")
  check("JSON_QUERY", "{\"a\":1}", "$", "={\"a\":1}")
  check(
    "JSON_VALUE", "1", "$", "E13609/1 JSON text is not properly formatted. Unexpected character '1' is found at position 0.",
  )
  check(
    "JSON_QUERY", "1", "$", "E13609/1 JSON text is not properly formatted. Unexpected character '1' is found at position 0.",
  )
  check(
    "JSON_VALUE", "\"text\"", "$", "E13609/1 JSON text is not properly formatted. Unexpected character '\"' is found at position 0.",
  )
  check(
    "JSON_QUERY", "\"text\"", "$", "E13609/1 JSON text is not properly formatted. Unexpected character '\"' is found at position 0.",
  )
  check(
    "JSON_VALUE", "null", "$", "E13609/1 JSON text is not properly formatted. Unexpected character 'n' is found at position 0.",
  )
  check(
    "JSON_QUERY", "null", "$", "E13609/1 JSON text is not properly formatted. Unexpected character 'n' is found at position 0.",
  )
  check("JSON_VALUE", "{\"a\":1,\"a\":2}", "$.a", "=1")
  check("JSON_QUERY", "{\"a\":1,\"a\":2}", "$.a", "NULL")
  check("JSON_VALUE", "{\"a\":1}", "$.missing", "NULL")
  check("JSON_QUERY", "{\"a\":1}", "$.missing", "NULL")
  check("JSON_VALUE", "{\"a\":1}", "$.a.x", "NULL")
  check("JSON_QUERY", "{\"a\":1}", "$.a.x", "NULL")
  check("JSON_VALUE", "{\"a\":\"text\"}", "$.a", "=text")
  check("JSON_QUERY", "{\"a\":\"text\"}", "$.a", "NULL")
  check("JSON_VALUE", "{\"a\":{\"x\":1}}", "$.a", "NULL")
  check("JSON_QUERY", "{\"a\":{\"x\":1}}", "$.a", "={\"x\":1}")
  check(
    "JSON_VALUE", "{\"a\":x,\"b\":1}", "$.b", "E13609/1 JSON text is not properly formatted. Unexpected character 'x' is found at position 5.",
  )
  check(
    "JSON_QUERY", "{\"a\":x,\"b\":1}", "$.b", "E13609/1 JSON text is not properly formatted. Unexpected character 'x' is found at position 5.",
  )
  check("JSON_VALUE", "{\"a\":1,\"b\":x}", "$.a", "=1")
  check("JSON_QUERY", "{\"a\":1,\"b\":x}", "$.a", "NULL")
  check("JSON_VALUE", "{\"a\":{},\"b\":x}", "$.a", "NULL")
  check("JSON_QUERY", "{\"a\":{},\"b\":x}", "$.a", "={}")
  check(
    "JSON_VALUE", "{\"a\":1,\"b\":x}", "$.missing", "E13609/1 JSON text is not properly formatted. Unexpected character 'x' is found at position 11.",
  )
  check(
    "JSON_QUERY", "{\"a\":1,\"b\":x}", "$.missing", "E13609/1 JSON text is not properly formatted. Unexpected character 'x' is found at position 11.",
  )
  check(
    "JSON_VALUE", "{\"a\":{\"x\":1", "$.a", "E13609/1 JSON text is not properly formatted. Unexpected character '.' is found at position 11.",
  )
  check(
    "JSON_QUERY", "{\"a\":{\"x\":1", "$.a", "E13609/1 JSON text is not properly formatted. Unexpected character '.' is found at position 11.",
  )
  check("JSON_VALUE", "{\"a\":1", "$.a", "=1")
  check("JSON_QUERY", "{\"a\":1", "$.a", "NULL")
  check("JSON_VALUE", "{\"a\":{}", "$.a", "NULL")
  check("JSON_QUERY", "{\"a\":{}", "$.a", "={}")
  check("JSON_VALUE", "{\"a\":1} x", "$.a", "=1")
  check("JSON_QUERY", "{\"a\":1} x", "$.a", "NULL")
  check("JSON_VALUE", "[1,x]", "$[0]", "=1")
  check("JSON_QUERY", "[1,x]", "$[0]", "NULL")
  check(
    "JSON_VALUE", "[x,1]", "$[1]", "E13609/1 JSON text is not properly formatted. Unexpected character 'x' is found at position 1.",
  )
  check(
    "JSON_QUERY", "[x,1]", "$[1]", "E13609/1 JSON text is not properly formatted. Unexpected character 'x' is found at position 1.",
  )
  check("JSON_VALUE", "[1", "$[0]", "=1")
  check("JSON_QUERY", "[1", "$[0]", "NULL")
  check("JSON_VALUE", "[1,2]", "$[2]", "NULL")
  check("JSON_QUERY", "[1,2]", "$[2]", "NULL")
  check(
    "JSON_VALUE", "", "$", "E13609/1 JSON text is not properly formatted. Unexpected character '.' is found at position 0.",
  )
  check(
    "JSON_QUERY", "", "$", "E13609/1 JSON text is not properly formatted. Unexpected character '.' is found at position 0.",
  )
  check(
    "JSON_VALUE", "{\"a\":1}", "strict $.missing", "E13608/1 Property cannot be found on the specified JSON path.",
  )
  check(
    "JSON_QUERY", "{\"a\":1}", "strict $.missing", "E13608/1 Property cannot be found on the specified JSON path.",
  )
  check(
    "JSON_VALUE", "{\"a\":1}", "strict $.a.x", "E13608/1 Property cannot be found on the specified JSON path.",
  )
  check(
    "JSON_QUERY", "{\"a\":1}", "strict $.a.x", "E13608/1 Property cannot be found on the specified JSON path.",
  )
  check("JSON_VALUE", "{\"a\":\"text\"}", "strict $.a", "=text")
  check(
    "JSON_QUERY", "{\"a\":\"text\"}", "strict $.a", "E13624/2 Object or array cannot be found in the specified JSON path.",
  )
  check(
    "JSON_VALUE", "{\"a\":{\"x\":1}}", "strict $.a", "E13623/2 Scalar value cannot be found in the specified JSON path.",
  )
  check("JSON_QUERY", "{\"a\":{\"x\":1}}", "strict $.a", "={\"x\":1}")
  check(
    "JSON_VALUE", "{\"a\":{},\"b\":x}", "strict $.a", "E13623/2 Scalar value cannot be found in the specified JSON path.",
  )
  check("JSON_QUERY", "{\"a\":{},\"b\":x}", "strict $.a", "={}")
  check(
    "JSON_VALUE", "{\"a\":1,\"b\":x}", "strict $.missing", "E13609/1 JSON text is not properly formatted. Unexpected character 'x' is found at position 11.",
  )
  check(
    "JSON_QUERY", "{\"a\":1,\"b\":x}", "strict $.missing", "E13609/1 JSON text is not properly formatted. Unexpected character 'x' is found at position 11.",
  )
  check("JSON_VALUE", "{\"a\":1", "strict $.a", "=1")
  check(
    "JSON_QUERY", "{\"a\":1", "strict $.a", "E13624/2 Object or array cannot be found in the specified JSON path.",
  )
  check(
    "JSON_VALUE", "1", "strict $", "E13609/1 JSON text is not properly formatted. Unexpected character '1' is found at position 0.",
  )
  check(
    "JSON_QUERY", "1", "strict $", "E13609/1 JSON text is not properly formatted. Unexpected character '1' is found at position 0.",
  )
  check(
    "JSON_VALUE", "{\"a\":[1]}", "$.a[0", "E13607/14 JSON path is not properly formatted. Unexpected character '.' is found at position 5.",
  )
  check(
    "JSON_QUERY", "{\"a\":[1]}", "$.a[0", "E13607/14 JSON path is not properly formatted. Unexpected character '.' is found at position 5.",
  )
}

///|
test "JSON_VALUE 4000-unit limit" {
  let long = "x".repeat(4000)
  check("JSON_VALUE", "{\"a\":\"" + long + "\"}", "$.a", "=" + long)
  check("JSON_VALUE", "{\"a\":\"" + long + "x\"}", "$.a", "NULL")
  check("JSON_VALUE", "{\"a\":\"" + long + "x\",\"b\":x}", "$.a", "NULL")
}

///|
test "ISJSON types and depth" {
  assert_eq(@json.isjson("{\"a\":[1,true,null]}"), 1)
  assert_eq(@json.isjson("1"), 0)
  assert_eq(@json.isjson("1", ty=Value), 1)
  assert_eq(@json.isjson("true", ty=Scalar), 0)
  assert_eq(@json.isjson("\"s\"", ty=Scalar), 1)
  assert_eq(@json.isjson("[1] x"), 0)
  assert_eq(@json.isjson("{\"a\":1,}"), 0)
  assert_eq(@json.isjson("[01]"), 0)
  assert_eq(@json.isjson("{\"a\":1,\"a\":2}"), 1)
  // isjson-depth captures: scalar inside 128 containers ok, 129 raises 13606
  let ok = "[".repeat(128) + "1" + "]".repeat(128)
  assert_eq(@json.isjson(ok), 1)
  let deep = "[".repeat(129) + "1" + "]".repeat(129)
  try @json.isjson(deep) catch {
    e => assert_eq(e.number(), 13606)
  } noraise {
    _ => fail("expected 13606")
  }
  // empty container at level 129 accepted, 130 raises
  assert_eq(@json.isjson("[".repeat(129) + "]".repeat(129)), 1)
  // invalid syntax before the deep value returns 0
  assert_eq(@json.isjson("[x," + deep + "]"), 0)
}

///|
test "OPENJSON default schema" {
  let rows = @json.openjson(
    "{\"a\":1,\"b\":\"t\\u00e9\",\"c\":null,\"d\":[1, 2],\"e\":{\"x\":true},\"a\":false}",
  )
  assert_eq(rows.map(r => (r.key, r.value, r.ty)), [
    ("a", Some("1"), 2),
    ("b", Some("t\u{e9}"), 1),
    ("c", None, 0),
    ("d", Some("[1, 2]"), 4),
    ("e", Some("{\"x\":true}"), 5),
    ("a", Some("false"), 3),
  ])
  let arr = @json.openjson("{\"x\":[10,20]}", path="$.x")
  assert_eq(arr.map(r => r.key), ["0", "1"])
  assert_eq(@json.openjson("{\"x\":1}", path="$.missing"), [])
  assert_eq(@json.openjson("{\"x\":1}", path="$.x"), [])
  // OPENJSON validates the whole document, even after the selected value
  try @json.openjson("{\"x\":[1],\"y\":x}", path="$.x") catch {
    e => assert_eq(e.number(), 13609)
  } noraise {
    _ => fail("expected 13609")
  }
}
