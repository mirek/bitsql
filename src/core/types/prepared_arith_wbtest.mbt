///|
test "prepared arithmetic preserves typed values, NULLs and errors across families" {
  let coll = default_collation
  let utf8 = Collation::parse("Latin1_General_100_CI_AS_SC_UTF8").unwrap()
  let types : Array[SqlType] = [
    Bit,
    TinyInt,
    SmallInt,
    Int,
    BigInt,
    Decimal(12, 3),
    Money,
    SmallMoney,
    Real,
    Float,
    NVarChar(Some(1), coll),
    NVarChar(Some(4), coll),
    NVarChar(None, coll),
    NChar(2, coll),
    VarChar(Some(4), coll),
    VarChar(Some(4), utf8),
    VarBinary(Some(3)),
    DateTime,
    SmallDateTime,
  ]
  let values : Array[Value] = [
    Null,
    Bit(true),
    TinyInt(255),
    SmallInt(-32768),
    Int(-2147483648),
    Int(2147483647),
    Int(-1),
    Int(0),
    Int(1),
    BigInt(-9223372036854775808L),
    BigInt(9223372036854775807L),
    Float(1.5),
    Money(12500L),
    String("a"),
    String("é😀"),
    String("123"),
    String(""),
    Binary(b"abc"),
    DateTime(0, 0),
  ]
  for ta in types {
    for tb in types {
      for op in [Add, Sub, Mul, Div, Mod] {
        let rt = Some(arith_result_type(op, ta, tb)) catch { _ => None }
        if rt is Some(rt) {
          let operation = prepare_arith(op, ta, tb, rt).unwrap_or((a, b) => {
            arith_typed(op, a, ta, b, tb, rt)
          })
          for a in values {
            for b in values {
              let expected = Ok(arith_typed(op, a, ta, b, tb, rt)) catch {
                e => Err(e)
              }
              let actual = Ok(operation(a, b)) catch { e => Err(e) }
              assert_eq(actual, expected)
            }
          }
        }
      }
    }
  }
}
