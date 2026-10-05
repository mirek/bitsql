///|
test "integer membership agrees with sorted comparison including unknown and errors" {
  let values : Array[Array[@types.Value]] = [
    [],
    [SmallInt(-3), TinyInt(0), Int(7), BigInt(7L), Int(256)],
    [BigInt(-9223372036854775808L), BigInt(9223372036854775807L)],
    Array::makei(3000, i => @types.Value::Int(i / 3)),
    [String("a"), String("b")],
  ]
  let probes : Array[@types.Value] = [
    Null,
    SmallInt(-3),
    TinyInt(0),
    Int(7),
    BigInt(256L),
    BigInt(-9223372036854775808L),
    BigInt(9223372036854775807L),
    Float(7.0),
    Float(7.5),
    Bit(true),
    String("7"),
    String("not an integer"),
    Date(0),
  ]
  for vs in values {
    for has_null in [false, true] {
      let fast = Members::new(vs, has_null, None)
      let reference = { ..fast, integers: None, }
      for v in probes {
        let actual = Ok(fast.contains(v)) catch { e => Err(e) }
        let expected = Ok(reference.contains(v)) catch { e => Err(e) }
        assert_eq(actual, expected)
      }
      for n in -5..<1010 {
        let actual = Ok(fast.contains(Int(n))) catch { e => Err(e) }
        let expected = Ok(reference.contains(Int(n))) catch { e => Err(e) }
        assert_eq(actual, expected)
      }
    }
  }
}
