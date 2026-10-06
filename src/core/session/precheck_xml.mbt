///|
/// Batch-level compile errors of xml expressions: SQL Server compiles the
/// whole batch first, so `DECLARE @x xml = ...; SELECT @x.value('/a', ...)`
/// fails before the DECLARE runs (captured: harness/corpus/xml/methods,
/// type). Statements are bound against the batch's declared variables with
/// no tables: statements over tables are compiled when they run (deferred
/// name resolution) and are skipped here. Only xml-related compile errors
/// count, so this cannot invent errors for other features.
fn precheck_xml(
  stmts : Array[@ast.Stmt],
  types : Map[String, @types.SqlType],
) -> (@types.SqlError, Int)? {
  // every variable of the batch (137 is checked before this runs)
  let vars : Map[String, @bind.VarInfo] = Map([])
  for k, t in types {
    vars[k] = { slot: vars.length(), ty: t, }
  }
  let mut failure : (@types.SqlError, Int)? = None
  let check = (line : Int, f : (@bind.Env) -> Unit raise @types.SqlError) => {
    if failure is Some(_) {
      return
    }
    let env = @bind.Env::new(vars)
    f(env) catch {
      e => if xml_compile_error(e) { failure = Some((e, line)) }
    }
  }
  fn stmt(s : @ast.Stmt) -> Unit {
    let line = s.span.line
    match s.kind {
      Declare(vars_) =>
        for v in vars_ {
          match v.init {
            Some(i) =>
              check(line, env => {
                let b = @bind.bind_expr(env, i)
                match types.get(v.name.to_lower()) {
                  Some(t) =>
                    if !(b.kind is Lit(Null)) {
                      @types.check_assign(b.ty, t)
                    }
                  None => ()
                }
              })
            None => ()
          }
        }
      SetVar(n, _, e) =>
        check(line, env => {
          let b = @bind.bind_expr(env, e)
          match types.get(n.to_lower()) {
            Some(t) =>
              if !(b.kind is Lit(Null)) {
                @types.check_assign(b.ty, t)
              }
            None => ()
          }
        })
      Select(q) => check(line, env => ignore(@bind.bind_query(env, q)))
      Print(e) =>
        check(line, env => {
          let b = @bind.bind_expr(env, e)
          if b.ty is (Xml | Json) {
            // captured: PRINT of xml or json is a compile-time 257
            // (xml/type#064, json4/type-compare)
            raise @types.implicit_conversion_error(
              b.ty,
              NVarChar(Some(1), @types.default_collation),
            )
          }
        })
      If(_, a, b) => {
        stmt(a)
        if b is Some(x) {
          stmt(x)
        }
      }
      While(_, b) => stmt(b)
      Block(list) => list.each(stmt)
      TryCatch(a, b) => {
        a.each(stmt)
        b.each(stmt)
      }
      _ => ()
    }
  }

  for s in stmts {
    stmt(s)
  }
  failure
}

///|
/// Compile errors of xml and json-type expressions (numbers and messages
/// captured: xml/, json4/).
fn xml_compile_error(e : @types.SqlError) -> Bool {
  let m = e.message()
  match e.number() {
    258
    | 227
    | 8172
    | 8137
    | 493
    | 318
    | 2389
    | 2209
    | 2395
    | 2396
    | 9500
    | 305
    | 421
    | 5335
    | 13636 => true
    n if n >= 6800 && n < 6900 => true
    42204 if e.state() == 1 => true
    189 if m.has_prefix("The vector_distance function") => true
    174 =>
      m.has_prefix("The vector_distance function") ||
      m.has_prefix("The vector_norm function") ||
      m.has_prefix("The vector_normalize function") ||
      m.has_prefix("The vectorproperty function") ||
      m.has_prefix("The value function") ||
      m.has_prefix("The query function") ||
      m.has_prefix("The exist function")
    402 | 8116 | 8117 | 257 | 206 | 529 =>
      m.contains("xml") || m.contains("json") || m.contains("vector")
    _ => false
  }
}
