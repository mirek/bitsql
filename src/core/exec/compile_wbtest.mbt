///|
test "compiled CHAR and NCHAR preserve interpreted values and errors" {
  let ctx : Ctx = {
    rt: Runtime::new(database="master", spid=51, now=0L, seed=1L),
    vars: [],
    row: [],
    outer: [],
    scan_row: (_, _, _) => (),
    source: (_, _) => [],
    ext: (_, _) => None,
    user_fn: no_user_fn,
    user_table: no_user_table,
    seek: no_seek,
    seek_json: no_json_seek,
    vector_search: no_vector_search,
    profile: None,
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

///|
test "prepared compiled arithmetic preserves operand evaluation and deferred errors" {
  let ctx : Ctx = {
    rt: Runtime::new(database="master", spid=51, now=0L, seed=1L),
    vars: [],
    row: [],
    outer: [],
    scan_row: (_, _, _) => (),
    source: (_, _) => [],
    ext: (_, _) => None,
    user_fn: no_user_fn,
    user_table: no_user_table,
    seek: no_seek,
    seek_json: no_json_seek,
    vector_search: no_vector_search,
    profile: None,
    stamp: no_stamp,
  }
  let zero : @ir.Expr = { kind: Lit(Int(0)), ty: Int, nullable: false, }
  let one : @ir.Expr = { kind: Lit(Int(1)), ty: Int, nullable: false, }
  let null : @ir.Expr = { kind: Lit(Null), ty: Int, nullable: true, }
  let bad : @ir.Expr = {
    kind: Arith(Div, one, zero),
    ty: Int,
    nullable: false,
  }
  let invalid : @ir.Expr = {
    kind: Arith(Add, { kind: Lit(Bit(true)), ty: Bit, nullable: false, }, {
      kind: Lit(Bit(false)),
      ty: Bit,
      nullable: false,
    }),
    ty: Bit,
    nullable: false,
  }
  for
    pair in [
      (null, bad),
      (bad, null),
      (bad, invalid),
      (invalid, bad),
      (null, one),
      (one, zero),
    ] {
    let ops : Array[@types.ArithOp] = [Add, Sub, Mul, Div, Mod]
    for op in ops {
      let expr : @ir.Expr = {
        kind: Arith(op, pair.0, pair.1),
        ty: Int,
        nullable: true,
      }
      let compiled = compile(expr)
      let actual = Ok(compiled(ctx, [])) catch { e => Err(e) }
      let expected = Ok(eval(ctx, expr)) catch { e => Err(e) }
      assert_eq(actual, expected)
    }
  }
}

///|
/// Random integer expression trees over columns of every integer type,
/// NULLs, literals near the type limits and all arithmetic operators.
fn int_tree(seed : Ref[Int], depth : Int) -> @ir.Expr {
  let next = () => {
    seed.val = (seed.val * 1103515245 + 12345) & 0x7FFFFFFF
    seed.val
  }
  let types : Array[@types.SqlType] = [TinyInt, SmallInt, Int, BigInt, Bit]
  if depth == 0 || next() % 4 == 0 {
    if next() % 3 == 0 {
      let lits : Array[@types.Value] = [
        Int(0),
        Int(1),
        Int(-1),
        Int(7),
        Int(2147483647),
        Int(-2147483648),
        BigInt(9223372036854775807L),
        BigInt(-9223372036854775807L),
        SmallInt(32767),
        TinyInt(255),
        Null,
      ]
      let v = lits[next() % lits.length()]
      let ty : @types.SqlType = match v {
        BigInt(_) => BigInt
        SmallInt(_) => SmallInt
        TinyInt(_) => TinyInt
        _ => Int
      }
      return { kind: Lit(v), ty, nullable: v is Null, }
    }
    let i = next() % 5
    return { kind: Col(i), ty: types[i], nullable: true, }
  }
  let ops : Array[@types.ArithOp] = [Add, Sub, Mul, Div, Mod]
  let op = ops[next() % ops.length()]
  let a = int_tree(seed, depth - 1)
  let b = int_tree(seed, depth - 1)
  let ty = @types.arith_result_type(op, a.ty, b.ty) catch { _ => Int }
  { kind: Arith(op, a, b), ty, nullable: true, }
}

///|
test "unboxed integer expressions equal interpreted evaluation and errors" {
  let ctx : Ctx = {
    rt: Runtime::new(database="master", spid=51, now=0L, seed=1L),
    vars: [],
    row: [],
    outer: [],
    scan_row: (_, _, _) => (),
    source: (_, _) => [],
    ext: (_, _) => None,
    user_fn: no_user_fn,
    user_table: no_user_table,
    seek: no_seek,
    seek_json: no_json_seek,
    vector_search: no_vector_search,
    profile: None,
    stamp: no_stamp,
  }
  let rows : Array[Array[@types.Value]] = [
    [TinyInt(3), SmallInt(-5), Int(17), BigInt(4000000000L), Bit(true)],
    [TinyInt(0), SmallInt(0), Int(0), BigInt(0L), Bit(false)],
    [Null, SmallInt(32767), Int(-2147483648), BigInt(-1L), Null],
    [TinyInt(255), Null, Int(2147483647), Null, Bit(true)],
    [
      TinyInt(1),
      SmallInt(-32768),
      Int(-1),
      BigInt(-9223372036854775808L),
      Bit(false),
    ],
  ]
  let seed = Ref(42)
  let mut compared = 0
  for _ in 0..<3000 {
    let e = int_tree(seed, 3)
    let lit : @ir.Expr = {
      kind: Lit(Int(seed.val % 50)),
      ty: Int,
      nullable: false,
    }
    let exprs : Array[@ir.Expr] = [
      e,
      { kind: Cmp(Lt, e, lit, None), ty: Bit, nullable: true, },
      { kind: Cmp(Eq, lit, e, None), ty: Bit, nullable: true, },
      {
        kind: Call(Named("NCHAR"), [{ ..e, kind: e.kind, }]),
        ty: NChar(1, @types.default_collation),
        nullable: true,
      },
      {
        kind: Call(Named("CHAR"), [e]),
        ty: Char(1, @types.default_collation),
        nullable: true,
      },
    ]
    for x in exprs {
      // CHAR/NCHAR bind only integer arguments of up to int's range
      if x.kind is Call(_, [arg]) && !(arg.ty is (Int | SmallInt | TinyInt)) {
        continue
      }
      let compiled = compile(x)
      for row in rows {
        let actual = Ok(compiled(ctx, row)) catch { err => Err(err.number()) }
        let expected = Ok(eval(ctx.with_row(row), x)) catch {
          err => Err(err.number())
        }
        assert_eq(actual, expected)
        compared += 1
      }
    }
  }
  assert_true(compared > 30000)
}
