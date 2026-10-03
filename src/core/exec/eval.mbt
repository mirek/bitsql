///|
let true_ : @types.Value = Bit(true)

///|
let false_ : @types.Value = Bit(false)

///|
fn truth(v : @types.Value) -> Bool? {
  match v {
    Bit(b) => Some(b)
    Null => None
    _ => Some(true)
  }
}

///|
fn of_bool(b : Bool?) -> @types.Value {
  match b {
    Some(true) => true_
    Some(false) => false_
    None => Null
  }
}

///|
/// True when a predicate value is TRUE (not FALSE or UNKNOWN).
pub fn is_true(v : @types.Value) -> Bool {
  v is Bit(true)
}

///|
pub fn eval(ctx : Ctx, e : @ir.Expr) -> @types.Value raise @types.SqlError {
  match e.kind {
    Lit(v) => v
    Var(slot) => ctx.vars[slot]
    Col(i) => ctx.row[i]
    OuterCol(depth, i) => ctx.outer[ctx.outer.length() - depth][i]
    Cast(inner, try_~, style~) => {
      let v = eval(ctx, inner)
      if try_ {
        @types.try_cast(v, inner.ty, e.ty, style?)
      } else {
        @types.cast(v, inner.ty, e.ty, style?)
      }
    }
    Collate(a) => eval(ctx, a)
    Arith(op, a, b) => {
      let va = eval(ctx, a)
      let vb = eval(ctx, b)
      @types.arith(op, va, a.ty, vb, b.ty)
    }
    Neg(a) => @types.negate(eval(ctx, a), a.ty)
    BitNot(a) =>
      match eval(ctx, a) {
        Null => Null
        Bit(b) => Bit(!b)
        TinyInt(i) => TinyInt(i.lnot() & 0xFF)
        SmallInt(i) => SmallInt(i.lnot())
        Int(i) => Int(i.lnot())
        BigInt(i) => BigInt(i.lnot())
        _ => raise @types.invalid_operand_error(a.ty, Add)
      }
    BitOp(op, a, b) => {
      let va = eval(ctx, a)
      let vb = eval(ctx, b)
      match (va.as_int64(), vb.as_int64()) {
        (Some(x), Some(y)) => {
          let r = match op {
            And => x & y
            Or => x | y
            Xor => x ^ y
          }
          @types.int_value(e.ty, r)
        }
        _ => Null
      }
    }
    Concat(a, b) => @types.arith(Add, eval(ctx, a), a.ty, eval(ctx, b), b.ty)
    Cmp(op, a, b, coll) => {
      let va = eval(ctx, a)
      let vb = eval(ctx, b)
      // varchar operands compare as code page 1252 data (binary
      // collations order bytes; SQL_ collations use string sort)
      let ansi = a.ty.family() == FString && !a.ty.is_unicode()
      match @types.compare(va, vb, collation?=coll, ansi~) {
        None => Null
        Some(c) =>
          of_bool(
            Some(
              match op {
                Eq => c == 0
                Ne => c != 0
                Lt => c < 0
                Le => c <= 0
                Gt => c > 0
                Ge => c >= 0
              },
            ),
          )
      }
    }
    And(a, b) =>
      match truth(eval(ctx, a)) {
        Some(false) => false_
        ta =>
          match (ta, truth(eval(ctx, b))) {
            (_, Some(false)) => false_
            (Some(true), Some(true)) => true_
            _ => Null
          }
      }
    Or(a, b) =>
      match truth(eval(ctx, a)) {
        Some(true) => true_
        ta =>
          match (ta, truth(eval(ctx, b))) {
            (_, Some(true)) => true_
            (Some(false), Some(false)) => false_
            _ => Null
          }
      }
    Not(a) =>
      match truth(eval(ctx, a)) {
        Some(b) => of_bool(Some(!b))
        None => Null
      }
    IsNull(a, negated~) => of_bool(Some(eval(ctx, a).is_null() != negated))
    Like(a, p, escape~, negated~, collation~) => {
      let va = eval(ctx, a)
      let vp = eval(ctx, p)
      let ve = match escape {
        Some(x) => eval(ctx, x)
        None => Null
      }
      match (va, vp) {
        (String(s), String(pat)) => {
          let esc = match ve {
            String(x) if x.length() > 0 => Some(x.code_unit_at(0).to_int())
            _ => None
          }
          let ci = match collation {
            Some(c) => !c.case_sensitive
            None => true
          }
          let m = like_match(s, pat, esc, ci)
          of_bool(Some(m != negated))
        }
        (Null, _) | (_, Null) => Null
        _ => raise @types.not_supported("LIKE on non-character operands")
      }
    }
    InList(a, items, negated~, collation~) => {
      let va = eval(ctx, a)
      if va is Null {
        return Null
      }
      let mut unknown = false
      for item in items {
        match
          @types.compare(
            va,
            eval(ctx, item),
            collation?,
            ansi=a.ty.family() == FString && !a.ty.is_unicode(),
          ) {
          Some(0) => return of_bool(Some(!negated))
          None => unknown = true
          _ => ()
        }
      }
      if unknown {
        Null
      } else {
        of_bool(Some(negated))
      }
    }
    Case(branches, els) => {
      for b in branches {
        if is_true(eval(ctx, b.0)) {
          return eval(ctx, b.1)
        }
      }
      match els {
        Some(x) => eval(ctx, x)
        None => Null
      }
    }
    Call(f, args) => call(ctx, f, args, e)
    Global(g) => global(ctx, g)
    Subquery(plan) => {
      let rows = run(ctx.push_outer(ctx.row), plan)
      if rows.length() > 1 {
        raise @types.sql_error(
          512, "Subquery returned more than 1 value. This is not permitted when the subquery follows =, !=, <, <= , >, >= or when the subquery is used as an expression.",
        )
      }
      if rows.is_empty() {
        Null
      } else {
        rows[0][0]
      }
    }
    Exists(plan) =>
      of_bool(Some(!run(ctx.push_outer(ctx.row), plan).is_empty()))
    InQuery(a, plan, negated~, collation~) => {
      let va = eval(ctx, a)
      let rows = run(ctx.push_outer(ctx.row), plan)
      if rows.is_empty() {
        return of_bool(Some(negated))
      }
      if va is Null {
        return Null
      }
      let mut unknown = false
      for r in rows {
        match @types.compare(va, r[0], collation?) {
          Some(0) => return of_bool(Some(!negated))
          None => unknown = true
          _ => ()
        }
      }
      if unknown {
        Null
      } else {
        of_bool(Some(negated))
      }
    }
    Quantified(op, a, plan, all~, collation~) => {
      let va = eval(ctx, a)
      let rows = run(ctx.push_outer(ctx.row), plan)
      let mut unknown = false
      for r in rows {
        let t = match @types.compare(va, r[0], collation?) {
          None => None
          Some(c) => Some(cmp_holds(op, c))
        }
        match t {
          Some(true) => if !all { return true_ }
          Some(false) => if all { return false_ }
          None => unknown = true
        }
      }
      if unknown {
        Null
      } else {
        of_bool(Some(all))
      }
    }
    UserFn(id, args) => (ctx.user_fn)(id, args.map(a => eval(ctx, a)))
  }
}

///|
fn cmp_holds(op : @ir.CmpOp, c : Int) -> Bool {
  match op {
    Eq => c == 0
    Ne => c != 0
    Lt => c < 0
    Le => c <= 0
    Gt => c > 0
    Ge => c >= 0
  }
}

///|
fn global(ctx : Ctx, g : @ir.Global) -> @types.Value {
  let rt = ctx.rt
  match g {
    RowCount => Int(rt.rowcount.to_int())
    Error => Int(rt.error)
    TranCount => Int(rt.trancount)
    Identity => rt.identity
    FetchStatus => Int(rt.fetch_status)
    Spid => SmallInt(rt.spid)
    Version => String(rt.version)
    ServerName => String(rt.server_name)
    ServiceName => String("MSSQLSERVER")
    NestLevel => Int(rt.nest_level)
    // 5496 = the login defaults tedious sets (captured @@OPTIONS)
    Options => Int(5496 | ctx.rt.option_bits)
    Language => String("us_english")
    DateFirst => TinyInt(ctx.rt.datefirst)
    LockTimeout => Int(ctx.rt.lock_timeout)
    TextSize => Int(2147483647)
    MaxPrecision => TinyInt(38)
    DbTs => Binary(Bytes::make(8, b'\x00'))
    ProcId => Int(0)
    CursorRows => Int(rt.cursor_rows)
  }
}

///|
/// LIKE with %, _, [set], [^set] and an optional escape character.
pub fn like_match(s : String, p : String, esc : Int?, ci : Bool) -> Bool {
  let fold = (c : Int) => {
    if ci && c >= 'A'.to_int() && c <= 'Z'.to_int() {
      c + 32
    } else if ci && c >= 0xC0 && c <= 0xDE && c != 0xD7 {
      c + 32
    } else {
      c
    }
  }
  let sl = s.length()
  let pl = p.length()
  // memo[i][j]: does s[i..] match p[j..]; iterative DP from the end.
  let memo = FixedArray::make((sl + 1) * (pl + 1), 0) // 0 unknown, 1 yes, 2 no
  fn go(i : Int, j : Int) -> Bool {
    let key = i * (pl + 1) + j
    if memo[key] != 0 {
      return memo[key] == 1
    }
    let r = if j == pl {
      i == sl
    } else {
      let c = p.code_unit_at(j).to_int()
      if esc is Some(e) && c == e && j + 1 < pl {
        i < sl &&
        fold(s.code_unit_at(i).to_int()) == fold(p.code_unit_at(j + 1).to_int()) &&
        go(i + 1, j + 2)
      } else if c == '%'.to_int() {
        go(i, j + 1) || (i < sl && go(i + 1, j))
      } else if c == '_'.to_int() {
        i < sl && go(i + 1, j + 1)
      } else if c == '['.to_int() {
        let mut k = j + 1
        let negate = k < pl && p.code_unit_at(k).to_int() == '^'.to_int()
        if negate {
          k += 1
        }
        let start = k
        while k < pl &&
              (p.code_unit_at(k).to_int() != ']'.to_int() || k == start) {
          k += 1
        }
        if k >= pl {
          // no closing bracket: literal '['
          i < sl && fold(s.code_unit_at(i).to_int()) == c && go(i + 1, j + 1)
        } else if i >= sl {
          false
        } else {
          let ch = fold(s.code_unit_at(i).to_int())
          let mut hit = false
          let mut m = start
          while m < k {
            let lo = fold(p.code_unit_at(m).to_int())
            if m + 2 < k && p.code_unit_at(m + 1).to_int() == '-'.to_int() {
              let hi = fold(p.code_unit_at(m + 2).to_int())
              if ch >= lo && ch <= hi {
                hit = true
              }
              m += 3
            } else {
              if ch == lo {
                hit = true
              }
              m += 1
            }
          }
          hit != negate && go(i + 1, k + 1)
        }
      } else {
        i < sl &&
        fold(s.code_unit_at(i).to_int()) == fold(c) &&
        go(i + 1, j + 1)
      }
    }
    memo[key] = if r { 1 } else { 2 }
    r
  }

  // LIKE ignores trailing spaces of the value only when the pattern does too
  go(0, 0) || (s.length() > 0 && s.has_suffix(" ") && like_trim(s, p, esc, ci))
}

///|
fn like_trim(s : String, p : String, esc : Int?, ci : Bool) -> Bool {
  let mut n = s.length()
  while n > 0 && s.code_unit_at(n - 1).to_int() == ' '.to_int() {
    n -= 1
  }
  if n == s.length() {
    return false
  }
  like_match(s.unsafe_substring(start=0, end=n), p, esc, ci)
}
