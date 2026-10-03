///|
fn bits_to_double(is_real : Bool, hex : String) -> Double {
  let v = @string.parse_uint64(hex, base=16) catch { _ => abort("bad hex") }
  if is_real {
    Float::reinterpret_from_uint(v.to_uint()).to_double()
  } else {
    v.reinterpret_as_double()
  }
}

///|
test "float style 0 matches the captured SQL Server grid" {
  // msduck reference/float-default-grid.json
  let failures = []
  for row in float_grid {
    let (is_real, hex, expected) = row
    let got = @types.format_float_general(bits_to_double(is_real, hex))
    if got != expected {
      failures.push("\{hex}: got \{got}, expected \{expected}")
    }
  }
  assert_eq(failures.length(), 0, msg=failures.iter().take(10).join("\n"))
  assert_true(float_grid.length() > 1000)
}

///|
test "float style 0 basic shapes" {
  assert_eq(@types.format_float_general(0.0), "0")
  assert_eq(@types.format_float_general(-0.0), "-0")
  assert_eq(@types.format_float_general(1.5), "1.5")
  assert_eq(@types.format_float_general(123456.5), "123457")
  assert_eq(@types.format_float_general(1234567.0), "1.23457e+006")
  assert_eq(@types.format_float_general(0.0001), "0.0001")
  assert_eq(@types.format_float_general(0.00001), "1e-005")
  assert_eq(@types.format_float_general(1.0e300), "1e+300")
}

///|
test "float styles 1 and 2" {
  assert_eq(@types.format_float_scientific(12345.678901, 8), "1.2345679e+004")
  assert_eq(
    @types.format_float_scientific(12345.678901, 16),
    "1.234567890100000e+004",
  )
  assert_eq(@types.format_float_scientific(0.0, 8), "0.0000000e+000")
}

///|
test "parse float text" {
  assert_eq(@types.parse_float_text(" 1.5e3 "), Some(1500.0))
  assert_eq(@types.parse_float_text("-.5"), Some(-0.5))
  assert_eq(@types.parse_float_text("5."), Some(5.0))
  assert_eq(@types.parse_float_text(""), Some(0.0))
  assert_eq(@types.parse_float_text("+7"), Some(7.0))
  assert_eq(@types.parse_float_text("1e"), None)
  assert_eq(@types.parse_float_text("."), None)
  assert_eq(@types.parse_float_text("\t1"), None)
  assert_eq(@types.parse_float_text("0.1"), Some(0.1))
}
