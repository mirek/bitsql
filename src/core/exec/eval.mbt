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
        @types.try_cast(v, inner.ty, e.ty, style?, dates=ctx.rt.dates)
      } else {
        @types.cast(v, inner.ty, e.ty, style?, dates=ctx.rt.dates)
      }
    }
    // varchar data changes code page with its collation (captured:
    // settings/utf8, a UTF-8 varchar COLLATE'd to a CP1252 collation turns
    // '😀' into '??')
    Collate(a) =>
      match (eval(ctx, a), a.ty.collation(), e.ty.collation()) {
        (String(s), Some(from), Some(to)) if !e.ty.is_unicode() &&
          from.code_page != to.code_page => String(@types.to_code_page(s, to))
        (v, _, _) => v
      }
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
            String(x) if x.length() == 1 => Some(x.code_unit_at(0).to_int())
            // captured: ESCAPE 'xx' and ESCAPE '' are 506, state 2 when
            // any operand is Unicode (settings/like-escape-state)
            String(x) =>
              raise @types.sql_error(
                506,
                "The invalid escape character \"\{x}\" was specified in a LIKE predicate.",
                state=if a.ty.is_unicode() ||
                  p.ty.is_unicode() ||
                  escape.map(x => x.ty.is_unicode()).unwrap_or(false) {
                  2
                } else {
                  1
                },
              )
            _ => None
          }
          let coll = match collation {
            Some(c) => c
            None =>
              match (a.ty.collation(), p.ty.collation()) {
                (Some(c), _) | (_, Some(c)) => c
                _ => @types.default_collation
              }
          }
          let ansi = !a.ty.is_unicode() && !p.ty.is_unicode()
          let m = like_match(s, pat, esc, coll, ansi)
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
      let rows = subquery_rows(ctx, plan).0
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
    Exists(plan) => of_bool(Some(!subquery_rows(ctx, plan).0.is_empty()))
    InQuery(a, plan, negated~, collation~) => {
      let va = eval(ctx, a)
      let (rows, memo) = subquery_rows(ctx, plan)
      if rows.is_empty() {
        return of_bool(Some(negated))
      }
      if va is Null {
        return Null
      }
      // a memoized set: binary search over its sorted values
      if memo is Some(m) && m.members(collation) is Some(set) {
        return match set.contains(va) {
          Some(found) => of_bool(Some(found != negated))
          None => Null
        }
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
      let rows = subquery_rows(ctx, plan).0
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
    TranCount =>
      Int(
        if rt.stmt_dml {
          (if rt.trancount > 0 { rt.trancount } else { 1 }) + 1
        } else {
          rt.trancount
        },
      )
    Identity => rt.identity
    FetchStatus => Int(rt.fetch_status)
    Spid => SmallInt(rt.spid)
    Version => String(rt.version)
    ServerName => String(rt.server_name)
    ServiceName => String("MSSQLSERVER")
    NestLevel => Int(rt.nest_level)
    // 5496 = the login defaults tedious sets (captured @@OPTIONS); a SET
    // flips its bit (ANSI_WARNINGS OFF clears 8: 5488, captured msduck
    // session-property-context)
    Options => Int(5496 ^ ctx.rt.option_bits)
    Language => String(@types.language(ctx.rt.dates.language).name)
    DateFirst => TinyInt(ctx.rt.datefirst)
    LockTimeout => Int(ctx.rt.lock_timeout)
    TextSize => Int(2147483647)
    MaxPrecision => TinyInt(38)
    DbTs => Binary(Bytes::make(8, b'\x00'))
    ProcId => Int(0)
    CursorRows => Int(rt.cursor_rows)
  }
}
