// TVP_TYPE (0xF3) RPC parameters: MS-TDS example 4.14 ("TVP Insert
// Statement", tds-protocol skill examples.md §55) and the NULL table tedious
// writes for a null TYPES.TVP value (FF FF 00 00).

///|
test "TVP parameter of MS-TDS example 4.14" {
  // ALL_HEADERS (total length 4: none), proc "foo", OptionFlags 0, then
  // one unnamed TVP parameter: dbo.tvptype (INTN(1)), one row with 2
  let payload = @tds.from_hex(
    "04 00 00 00" +
    "03 00 66 00 6f 00 6f 00 00 00" +
    "00 00" +
    "f3 00 03 64 00 62 00 6f 00 07 74 00 76 00 70 00 74 00 79 00 70 00 65 00" +
    "01 00 00 00 00 00 00 00 26 01 00" +
    "00" +
    "01 01 02" +
    "00",
  )
  let req = @tds.decode_rpc(payload)
  let p = req.calls[0].params[0]
  let tvp = p.tvp.unwrap()
  assert_eq(tvp.schema, "dbo")
  assert_eq(tvp.name, "tvptype")
  assert_eq(tvp.columns.length(), 1)
  assert_eq(tvp.columns[0].type_info, IntN(1))
  debug_inspect(tvp.rows, content="Some([[Int(2)]])")
}

///|
test "TVP parameter: NULL table, then a scalar parameter" {
  let payload = @tds.from_hex(
    "04 00 00 00" +
    "03 00 66 00 6f 00 6f 00 00 00" +
    "02 40 00 74 00 00" +
    "f3 00 00 02 54 00 54 00" +
    "ff ff 00 00" +
    "02 40 00 6e 00 00 26 04 04 05 00 00 00",
  )
  let req = @tds.decode_rpc(payload)
  let params = req.calls[0].params
  assert_eq(params.length(), 2)
  assert_eq(params[0].name, "@t")
  assert_true(params[0].tvp.unwrap().rows is None)
  assert_eq(params[1].name, "@n")
  assert_eq(params[1].value, Int(5L))
}
