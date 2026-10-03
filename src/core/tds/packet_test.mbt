///|
test "frame splits by packet size and sets EOM last" {
  let payload = Bytes::make(10, b'\xAB')
  let framed = @tds.frame(
    @tds.PacketType::TabularResult,
    payload,
    packet_size=12,
  )
  // 3 packets: 4 + 4 + 2 payload bytes
  assert_eq(
    @tds.hex(framed),
    "04 00 00 0c 00 00 01 00 ab ab ab ab 04 00 00 0c 00 00 02 00 ab ab ab ab 04 01 00 0a 00 00 03 00 ab ab",
  )
}

///|
test "reassembler handles split chunks and multi-packet messages" {
  let framed = @tds.frame(
    @tds.PacketType::SqlBatch,
    b"hello world",
    packet_size=12,
  )
  let r = @tds.Reassembler::new()
  let mut got = []
  for i in 0..<framed.length() {
    got = got + r.push(framed[i:i + 1])
  }
  assert_eq(got.length(), 1)
  assert_eq(got[0].ty, @tds.PacketType::SqlBatch)
  assert_eq(got[0].payload, b"hello world")
  // two messages in one chunk
  let two = framed + @tds.frame(@tds.PacketType::Attention, b"")
  let msgs = r.push(two)
  assert_eq(msgs.length(), 2)
  assert_eq(msgs[1].ty, @tds.PacketType::Attention)
}

///|
test "reassembler rejects short length" {
  let r = @tds.Reassembler::new()
  try r.push(@tds.from_hex("01 01 00 04 00 00 01 00")) catch {
    e => inspect(e.message(), content="packet length 4 shorter than header")
  } noraise {
    _ => fail("expected error")
  }
}
