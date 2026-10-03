///|
fn bytes_of(f : (@tds.Writer) -> Unit raise) -> String raise {
  let w = @tds.Writer::new()
  f(w)
  @tds.hex(w.to_bytes())
}

///|
test "DONE tokens from MS-TDS examples 4.7 and 4.9" {
  assert_eq(
    bytes_of(w => @tds.write_done(w, Done, @tds.DONE_COUNT, @tds.CMD_SELECT, 1)),
    "fd 10 00 c1 00 01 00 00 00 00 00 00 00",
  )
  assert_eq(
    bytes_of(w => {
      @tds.write_done(
        w,
        DoneInProc,
        @tds.DONE_MORE | @tds.DONE_COUNT,
        @tds.CMD_SELECT,
        1,
      )
    }),
    "ff 11 00 c1 00 01 00 00 00 00 00 00 00",
  )
  assert_eq(
    bytes_of(w => @tds.write_done(w, DoneProc, 0, @tds.CMD_EXECUTE, 0)),
    "fe 00 00 e0 00 00 00 00 00 00 00 00 00",
  )
  // Attention acknowledgement, sent as its own message (tedious skill).
  assert_eq(
    bytes_of(w => @tds.write_done(w, Done, @tds.DONE_ATTN, 0, 0)),
    "fd 20 00 00 00 00 00 00 00 00 00 00 00",
  )
  assert_eq(bytes_of(w => @tds.write_return_status(w, 0)), "79 00 00 00 00")
}

///|
test "ENVCHANGE database from MS-TDS example 4.4" {
  assert_eq(
    bytes_of(w => @tds.write_envchange(w, Database("master", "master"))),
    "e3 1b 00 01 06 6d 00 61 00 73 00 74 00 65 00 72 00 06 6d 00 61 00 73 00 74 00 65 00 72 00",
  )
  assert_eq(
    bytes_of(w => {
      @tds.write_envchange(w, Collation(@tds.default_collation, b""))
    }),
    "e3 08 00 07 05 09 04 d0 00 34 00",
  )
  assert_eq(
    bytes_of(w => @tds.write_envchange(w, PacketSize(4096, 4096))),
    "e3 13 00 04 04 34 00 30 00 39 00 36 00 04 34 00 30 00 39 00 36 00",
  )
}

///|
test "LOGINACK layout (version big-endian)" {
  assert_eq(
    bytes_of(w => {
      @tds.write_loginack(
        w,
        tds_version=@tds.TDS_74,
        prog_name="Microsoft SQL Server",
        version=(17, 0, 0x0F, 0xE1),
      )
    }),
    "ad 32 00 01 74 00 00 04 14 4d 00 69 00 63 00 72 00 6f 00 73 00 6f 00 66 00 74 00 20 00 53 00 51 00 4c 00 20 00 53 00 65 00 72 00 76 00 65 00 72 00 11 00 0f e1",
  )
}

///|
test "COLMETADATA + ROW for nvarchar, int, decimal, datetime2" {
  let cols : Array[@tds.Column] = [
    {
      name: "bar",
      type_info: NVarChar(6, @tds.default_collation),
      flags: @tds.COL_NULLABLE,
      user_type: 0,
    },
    { name: "i", type_info: Int4, flags: 0, user_type: 0, },
    {
      name: "d",
      type_info: DecimalN(10, 2),
      flags: @tds.COL_NULLABLE,
      user_type: 0,
    },
    {
      name: "t",
      type_info: DateTime2(3),
      flags: @tds.COL_NULLABLE,
      user_type: 0,
    },
  ]
  let w = @tds.Writer::new()
  @tds.write_colmetadata(w, cols)
  @tds.write_row(w, cols, [
    Text("foo"),
    Int(-2),
    Decimal(true, b"\x39\x30"), // -123.45
    DateTime2(1, 10_000L * 1500), // 0001-01-02 00:00:01.500
  ])
  inspect(
    @tds.hex(w.to_bytes()),
    content=(
      #|81 04 00 00 00 00 00 01 00 e7 06 00 09 04 d0 00 34 03 62 00 61 00 72 00 00 00 00 00 00 00 38 01 69 00 00 00 00 00 01 00 6a 11 0a 02 01 64 00 00 00 00 00 01 00 2a 03 01 74 00 d1 06 00 66 00 6f 00 6f 00 fe ff ff ff 05 00 39 30 00 00 07 dc 05 00 00 01 00 00
    ),
  )
}

///|
test "value round trips through read_value" {
  let cases : Array[(@tds.TypeInfo, @tds.WireValue)] = [
    (IntN(4), Int(-5)),
    (IntN(8), Int(1L << 40)),
    (IntN(2), Null),
    (BitN, Int(1)),
    (FloatN(8), Float(1.5)),
    (MoneyN(8), Money(-12345678901L)),
    (Guid, Guid(Bytes::make(16, b'\x07'))),
    (DecimalN(38, 4), Decimal(false, b"\x01\x02\x03\x04\x05")),
    (Date, Date(738000)),
    (Time(7), Time(863999999999L)),
    (DateTime2(7), DateTime2(738000, 123L)),
    (DateTimeOffset(7), DateTimeOffset(738000, 123L, -330)),
    (NVarChar(@tds.MAX_LEN, @tds.default_collation), Text("long € text")),
    (NVarChar(@tds.MAX_LEN, @tds.default_collation), Null),
    (BigVarChar(20, @tds.default_collation), Text("caf\u{e9} \u{20ac}")),
    (BigVarBinary(4), Binary(b"\x00\xff")),
  ]
  for c in cases {
    let (ti, v) = c
    let w = @tds.Writer::new()
    @tds.write_value(w, ti, v)
    let got = @tds.read_value(@tds.Reader::new(w.to_bytes()), ti)
    let expected = match v {
      Decimal(n, mag) => {
        // magnitude comes back padded to a whole 4-byte group
        let padded = Bytes::makei((mag.length() + 3) / 4 * 4, i => {
          if i < mag.length() {
            mag[i]
          } else {
            b'\x00'
          }
        })
        @tds.WireValue::Decimal(n, padded)
      }
      _ => v
    }
    assert_eq(got, expected)
  }
}

///|
test "RPC example 4.8 and sp_executesql by id" {
  let payload = @tds.from_hex(
    "16 00 00 00 12 00 00 00 02 00 00 00 00 00 00 00 00 01 00 00 00 00 04 00 66 00 6F 00 6F 00 33 00 00 00 00 02 26 02 00",
  )
  let req = @tds.decode_rpc(payload)
  assert_eq(req.calls.length(), 1)
  assert_eq(req.calls[0].proc, Name("foo3"))
  assert_eq(req.calls[0].params.length(), 1)
  let p = req.calls[0].params[0]
  assert_true(p.default_value)
  assert_eq(p.type_info, IntN(2))
  assert_eq(p.value, Null)
  // sp_executesql by ProcID with @stmt nvarchar and one int parameter
  let w = @tds.Writer::new()
  w.bytes(
    @tds.from_hex(
      "16 00 00 00 12 00 00 00 02 00 00 00 00 00 00 00 00 01 00 00 00 00",
    ),
  )
  w.u16le(0xFFFF)
  w.u16le(10)
  w.u16le(0)
  for
    param in [
      (
        "",
        @tds.TypeInfo::NVarChar(@tds.MAX_LEN, @tds.default_collation),
        @tds.WireValue::Text("select @a"),
      ),
      ("", NVarChar(@tds.MAX_LEN, @tds.default_collation), Text("@a int")),
      ("@a", IntN(4), Int(42)),
    ] {
    w.b_varchar(param.0)
    w.u8(0)
    @tds.write_type_info(w, param.1)
    @tds.write_value(w, param.1, param.2)
  }
  let req = @tds.decode_rpc(w.to_bytes())
  assert_eq(req.calls[0].proc.canonical_name(), "sp_executesql")
  assert_eq(req.calls[0].params.map(p => p.value), [
    Text("select @a"),
    Text("@a int"),
    Int(42),
  ])
}

///|
test "ORDER token" {
  assert_eq(bytes_of(w => @tds.write_order(w, [2, 0])), "a9 04 00 02 00 00 00")
}
