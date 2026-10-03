// Normalized expression text of CHECK / DEFAULT / computed-column / filter
// definitions, as SQL Server regenerates it from the parse tree
// (sys.check_constraints.definition, INFORMATION_SCHEMA.COLUMNS.COLUMN_DEFAULT,
// ...). Rules captured on SQL Server 17.0 (corpus catalog/definitions):
// the whole text is wrapped in parentheses, numeric literals are
// parenthesized, columns bracketed, operators unspaced, built-in function
// names lower-cased, IN lists become OR chains (reversed), BETWEEN becomes
// >= AND <=, CAST becomes CONVERT([type],...).

///|
/// Normalized definition of an expression stored as source text. Falls back
/// to the source text when it does not parse.
fn definition_text(raw : String) -> String {
  let e = @parse.parse_expr(raw) catch { _ => return raw }
  "(" + def_expr(strip_parens(e), 0) + ")"
}

///|
fn strip_parens(e : @ast.Expr) -> @ast.Expr {
  match e.kind {
    Paren(x) => strip_parens(x)
    _ => e
  }
}

///|
/// Binding strength used to decide where parentheses are needed:
/// OR 1, AND 2, NOT 3, predicates 4, + - 5, * / % 6, unary/atoms 9.
fn def_prec(e : @ast.Expr) -> Int {
  match e.kind {
    Or(_, _) => 1
    InList(_, _, negated~) => if negated { 3 } else { 1 }
    And(_, _) => 2
    Between(_, _, _, negated~) => if negated { 3 } else { 2 }
    Not(_) => 3
    Like(_, _, negated~, ..) => if negated { 3 } else { 4 }
    Compare(_, _, _) | IsNull(_, ..) => 4
    Binary(Add | Sub, _, _) => 5
    Binary(Mul | Div | Mod, _, _) => 6
    Paren(x) => def_prec(x)
    _ => 9
  }
}

///|
fn def_wrap(e : @ast.Expr, min : Int) -> String {
  let inner = strip_parens(e)
  let text = def_expr(inner, min)
  if def_prec(inner) < min {
    "(" + text + ")"
  } else {
    text
  }
}

///|
fn def_type(t : @ast.TypeName) -> String {
  let name = "[" + t.name.to_lower() + "]"
  if t.args.is_empty() {
    name
  } else {
    name +
    "(" +
    t.args
    .map(a => {
      match a {
        Num(n) => n
        Max => "max"
      }
    })
    .join(",") +
    ")"
  }
}

///|
fn def_cmp(op : @ast.CmpOp) -> String {
  match op {
    Eq => "="
    Ne => "<>"
    Lt => "<"
    Le => "<="
    Gt => ">"
    Ge => ">="
    NotLt => "!<"
    NotGt => "!>"
  }
}

///|
fn def_number(text : String) -> String {
  "(" + text + ")"
}

///|
fn def_expr(e : @ast.Expr, ctx : Int) -> String {
  ignore(ctx)
  match e.kind {
    Null => "NULL"
    Default => "DEFAULT"
    IntLit(t) =>
      // integers beyond int become numeric literals: `3000000000.`
      if t.length() > 10 || (t.length() == 10 && t > "2147483647") {
        def_number(t + ".")
      } else {
        def_number(t)
      }
    DecimalLit(t) => def_number(t)
    FloatLit(t) =>
      match @types.parse_float_text(t) {
        Some(d) => def_number(@types.format_float_scientific(d, 17))
        None => def_number(t)
      }
    MoneyLit(t) => {
      let body = if t.has_prefix("$") {
        t.unsafe_substring(start=1, end=t.length())
      } else {
        t
      }
      match @types.Decimal::parse(body) {
        Some(d) => def_number("$" + d.rescale(4).to_string())
        None => def_number(t)
      }
    }
    StrLit(v, national~) =>
      (if national { "N'" } else { "'" }) +
      v.replace_all(old="'", new="''") +
      "'"
    BinaryLit(t) => t
    Var(n) => n
    GlobalVar(n) => n
    Column(parts) => parts.map(p => "[" + p.name + "]").join(".")
    Unary(Neg, x) =>
      match strip_parens(x).kind {
        IntLit(t) | DecimalLit(t) => def_number("-" + t)
        _ => "-" + def_wrap(x, 9)
      }
    Unary(Plus, x) => def_wrap(x, 9)
    Unary(BitNot, x) => "~" + def_wrap(x, 9)
    Binary(op, l, r) => {
      let (sym, p) = match op {
        Add => ("+", 5)
        Sub => ("-", 5)
        Mul => ("*", 6)
        Div => ("/", 6)
        Mod => ("%", 6)
        BitAnd => ("&", 0)
        BitOr => ("|", 0)
        BitXor => ("^", 0)
      }
      if p == 0 {
        // bitwise operators are always parenthesized (captured)
        "(" + def_wrap(l, 9) + sym + def_wrap(r, 9) + ")"
      } else {
        def_wrap(l, p) + sym + def_wrap(r, p + 1)
      }
    }
    Compare(op, l, r) => def_wrap(l, 5) + def_cmp(op) + def_wrap(r, 5)
    Not(x) => "NOT " + def_wrap(x, 4)
    And(l, r) => def_wrap(l, 2) + " AND " + def_wrap(r, 2)
    Or(l, r) => def_wrap(l, 1) + " OR " + def_wrap(r, 1)
    IsNull(x, negated~) =>
      def_wrap(x, 5) + (if negated { " IS NOT NULL" } else { " IS NULL" })
    Like(x, p, escape~, negated~) => {
      let base = def_wrap(x, 5) +
        " like " +
        def_wrap(p, 5) +
        (match escape {
          Some(esc) => " escape " + def_wrap(esc, 5)
          None => ""
        })
      if negated {
        "NOT " + base
      } else {
        base
      }
    }
    Between(x, lo, hi, negated~) => {
      let base = def_wrap(x, 5) +
        ">=" +
        def_wrap(lo, 5) +
        " AND " +
        def_wrap(x, 5) +
        "<=" +
        def_wrap(hi, 5)
      if negated {
        "NOT (" + base + ")"
      } else {
        base
      }
    }
    InList(x, items, negated~) => {
      let parts = []
      for k = items.length() - 1; k >= 0; k = k - 1 {
        parts.push(def_wrap(x, 5) + "=" + def_wrap(items[k], 5))
      }
      let base = parts.join(" OR ")
      if negated {
        "NOT (" + base + ")"
      } else {
        base
      }
    }
    Case(operand~, whens~, else_~) => {
      let sb = StringBuilder()
      sb.write_string("case")
      match operand {
        Some(o) => sb.write_string(" " + def_wrap(o, 5))
        None => ()
      }
      for w in whens {
        sb.write_string(" when " + def_expr(strip_parens(w.0), 0))
        sb.write_string(" then " + def_wrap(w.1, 5))
      }
      match else_ {
        Some(x) => sb.write_string(" else " + def_wrap(x, 5))
        None => ()
      }
      sb.write_string(" end")
      sb.to_string()
    }
    Cast(x, t, try_~) =>
      (if try_ { "TRY_CONVERT(" } else { "CONVERT(" }) +
      def_type(t) +
      "," +
      def_wrap(x, 0) +
      ")"
    Convert(t, x, style~, try_~) =>
      (if try_ { "TRY_CONVERT(" } else { "CONVERT(" }) +
      def_type(t) +
      "," +
      def_wrap(x, 0) +
      (match style {
        Some(st) => "," + def_wrap(st, 0)
        None => ""
      }) +
      ")"
    Call(c) => {
      let n = c.name.base()
      let name = match n.to_upper() {
        "CURRENT_TIMESTAMP" => "getdate"
        "SYSTEM_USER" => "suser_sname"
        "CURRENT_USER" | "SESSION_USER" | "USER" => "user_name"
        _ =>
          if c.name.parts.length() > 1 {
            c.name.parts.map(p => "[" + p.name + "]").join(".")
          } else {
            n.to_lower()
          }
      }
      if c.star {
        name + "(*)"
      } else {
        name + "(" + c.args.map(a => def_wrap(a, 0)).join(",") + ")"
      }
    }
    Paren(x) => def_wrap(x, ctx)
    Collate(x, c) => def_wrap(x, 9) + " collate " + c.name
    _ => "?"
  }
}
