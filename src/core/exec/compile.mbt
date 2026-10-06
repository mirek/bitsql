// Expression compilation to closures ("closure compilation": Feeley &
// Lapalme, "Using closures for code generation", 1987; staging an
// interpreter as in Tahboub, Essertel & Rompf, "How to Architect a Query
// Compiler, Revisited", SIGMOD 2018). docs/design/performance.md.
//
// An operator compiles each expression once per run and calls the closure
// per row with the row as an argument. That removes the per-row
// `Ctx::with_row` copy (a 25-field record whose fields are increfed and
// released for every row) and resolves types, collations and result types
// once instead of per row. Node kinds without a specialization fall back to
// `eval` on a context carrying the row, so behavior is `eval`'s by
// construction: a specialization must evaluate operands in the same order
// and raise the same errors as the matching `eval` arm.

///|
/// A compiled expression: evaluates against the context and the current row.
pub type Compiled = (Ctx, Array[@types.Value]) -> @types.Value raise @types.SqlError

///|
pub fn compile(e : @ir.Expr) -> Compiled {
  match e.kind {
    Lit(v) => (_, _) => v
    Col(i) => (_, r) => r[i]
    Var(slot) => (c, _) => c.vars[slot]
    OuterCol(depth, i) => (c, _) => c.outer[c.outer.length() - depth][i]
    Cast(inner, try_~, style~) => {
      let ci = compile(inner)
      let from = inner.ty
      let to = e.ty
      if try_ {
        (c, r) => @types.try_cast(ci(c, r), from, to, style?, dates=c.rt.dates)
      } else {
        (c, r) => @types.cast(ci(c, r), from, to, style?, dates=c.rt.dates)
      }
    }
    Concat(a, b) => compile({ ..e, kind: Arith(Add, a, b), })
    Arith(op, a, b) => {
      let ca = compile(a)
      let cb = compile(b)
      let ta = a.ty
      let tb = b.ty
      // an invalid operand type raises when a row is evaluated, as in eval
      let rt : @types.SqlType? = Some(@types.arith_result_type(op, ta, tb)) catch {
        _ => None
      }
      match rt {
        Some(rt) =>
          match @types.prepare_arith(op, ta, tb, rt) {
            Some(arithmetic) =>
              (c, r) => {
                let va = ca(c, r)
                let vb = cb(c, r)
                arithmetic(va, vb)
              }
            None =>
              (c, r) => {
                let va = ca(c, r)
                let vb = cb(c, r)
                @types.arith_typed(op, va, ta, vb, tb, rt)
              }
          }
        None =>
          (c, r) => {
            let va = ca(c, r)
            let vb = cb(c, r)
            @types.arith(op, va, ta, vb, tb)
          }
      }
    }
    Cmp(op, a, b, coll) => {
      let ca = compile(a)
      let cb = compile(b)
      let ansi = a.ty.family() == FString && !a.ty.is_unicode()
      (c, r) => {
        let va = ca(c, r)
        let vb = cb(c, r)
        match (va, vb) {
          (Int(x), Int(y)) => of_bool(Some(cmp_holds(op, x.compare(y))))
          // integers of different types compare by value (exact in Int64)
          (
            TinyInt(_)
            | SmallInt(_)
            | Int(_)
            | BigInt(_),
            TinyInt(_)
            | SmallInt(_)
            | Int(_)
            | BigInt(_),
          ) =>
            of_bool(
              Some(cmp_holds(op, va.int64_or(0L).compare(vb.int64_or(0L)))),
            )
          _ =>
            match @types.compare(va, vb, collation?=coll, ansi~) {
              None => Null
              Some(k) => of_bool(Some(cmp_holds(op, k)))
            }
        }
      }
    }
    And(a, b) => {
      let ca = compile(a)
      let cb = compile(b)
      (c, r) => {
        match truth(ca(c, r)) {
          Some(false) => false_
          ta =>
            match (ta, truth(cb(c, r))) {
              (_, Some(false)) => false_
              (Some(true), Some(true)) => true_
              _ => Null
            }
        }
      }
    }
    Or(a, b) => {
      let ca = compile(a)
      let cb = compile(b)
      (c, r) => {
        match truth(ca(c, r)) {
          Some(true) => true_
          ta =>
            match (ta, truth(cb(c, r))) {
              (_, Some(true)) => true_
              (Some(false), Some(false)) => false_
              _ => Null
            }
        }
      }
    }
    Not(a) => {
      let ca = compile(a)
      (c, r) => {
        match truth(ca(c, r)) {
          Some(b) => of_bool(Some(!b))
          None => Null
        }
      }
    }
    IsNull(a, negated~) => {
      let ca = compile(a)
      (c, r) => of_bool(Some(ca(c, r).is_null() != negated))
    }
    Case(branches, els) => {
      let cs = branches.map(b => (compile(b.0), compile(b.1)))
      let ce = els.map(compile)
      (c, r) => {
        for b in cs {
          if is_true((b.0)(c, r)) {
            return (b.1)(c, r)
          }
        }
        match ce {
          Some(x) => x(c, r)
          None => Null
        }
      }
    }
    Call(Named(name), [arg]) if name == "CHAR" || name == "NCHAR" => {
      let ca = compile(arg)
      let ansi = name == "CHAR"
      let collation = e.ty.collation().unwrap_or(@types.default_collation)
      (c, r) => char_value(ca(c, r), ansi, collation~)
    }
    Call(f, args) => {
      let cs = args.map(compile)
      (c, r) => call_values(c, f, cs.map(g => g(c, r)), args, e)
    }
    Exists(plan) =>
      (c, r) => of_bool(Some(!subquery_rows_at(c, plan, r).0.is_empty()))
    Subquery(plan) =>
      (c, r) => scalar_subquery_value(subquery_rows_at(c, plan, r).0)
    _ => (c, r) => eval(c.with_row(r), e)
  }
}
