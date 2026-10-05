///|
test "compiled CHAR and NCHAR preserve interpreted values and errors" {
  let ctx : Ctx = {
    rt: Runtime::new(database="master", spid=51, now=0L, seed=1L),
    vars: [],
    row: [],
    outer: [],
    source: (_, _) => [],
    ext: (_, _) => None,
    user_fn: no_user_fn,
    user_table: no_user_table,
    seek: no_seek,
    stamp: no_stamp,
  }
  for name in ["CHAR", "NCHAR"] {
    let arg : @ir.Expr = { kind: Col(0), ty: Int, nullable: true, }
    let e : @ir.Expr = {
      kind: Call(Named(name), [arg]),
      ty: if name == "CHAR" {
        Char(1, @types.default_collation)
      } else {
        NChar(1, @types.default_collation)
      },
      nullable: true,
    }
    let compiled = compile(e)
    // Exhaust both CHAR's code page and NCHAR's UTF-16 code units, including
    // lone surrogates, plus invalid values and NULL. The reference is the
    // pre-specialization implementation; no SQL expectations are invented.
    for n in -1..<65537 {
      let value : @types.Value = Int(n)
      let expected : @types.Value = if n < 0 ||
        n > (if name == "CHAR" { 255 } else { 65535 }) {
        Null
      } else if name == "CHAR" {
        String(@types.cp1252_decode(n).unsafe_to_char().to_string())
      } else {
        String(n.unsafe_to_char().to_string())
      }
      assert_eq(compiled(ctx, [value]), expected)
    }
    let values : Array[@types.Value] = [
      Null,
      Int(-2147483648),
      Int(2147483647),
      BigInt(2147483648L),
    ]
    for value in values {
      let row = [value]
      let actual = Ok(compiled(ctx, row)) catch { e => Err(e) }
      let expected = Ok(eval(ctx.with_row(row), e)) catch { e => Err(e) }
      assert_eq(actual, expected)
    }
    // An error in the operand must still propagate from the compiled call.
    let bad : @ir.Expr = {
      kind: Arith(Div, { kind: Lit(Int(1)), ty: Int, nullable: false, }, {
        kind: Lit(Int(0)),
        ty: Int,
        nullable: false,
      }),
      ty: Int,
      nullable: false,
    }
    let bad_call = { ..e, kind: Call(Named(name), [bad]), }
    let actual = Ok(compile(bad_call)(ctx, [])) catch { e => Err(e) }
    let expected = Ok(eval(ctx, bad_call)) catch { e => Err(e) }
    assert_eq(actual, expected)
  }
}
