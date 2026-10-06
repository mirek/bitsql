// Normalized expression text of CHECK / DEFAULT / computed-column / filter
// definitions, as SQL Server regenerates it from the parse tree
// (sys.check_constraints.definition, INFORMATION_SCHEMA.COLUMNS.COLUMN_DEFAULT,
// ...). Rules captured on SQL Server 17.0 (corpus catalog/definitions,
// msduck gaps-catalog v2-check-definitions / v2-default-definitions /
// v2-computed-definitions): the whole text is wrapped in parentheses,
// numeric literals are parenthesized (leading zeros dropped, -0 is (0)),
// columns bracketed, operators unspaced, built-in function names
// lower-cased, IN lists become OR chains (reversed), BETWEEN becomes >= AND
// <=, CAST becomes CONVERT([type],...), TRY_CONVERT without a style becomes
// TRY_CAST(x AS [type]), IIF becomes a searched CASE, YEAR/MONTH/DAY become
// datepart(...) and datepart arguments take their canonical names.
//
// Parentheses follow operator classes (`def_class`): an arithmetic operand
// of the same or a lower class is wrapped on either side (`((a)-(b))-(c)`,
// `[a]/([b]*[c])`), comparison operands are wrapped when additive or a
// unary minus (`([a]+[b])=[c]`, but `[a]*[b]>(0)`), bitwise operations
// always wrap themselves, the left operand of AND/OR is wrapped only when
// of a lower class and the right one also when of the same class
// (`a OR (b OR c)` keeps its parentheses, `a OR b OR c` has none).

///|
/// Normalized definition of an expression stored as source text. Falls back
/// to the source text when it does not parse.
fn definition_text(raw : String) -> String {
  let e = @parse.parse_expr(raw) catch { _ => return raw }
  "(" + def_expr(strip_parens(e)) + ")"
}

///|
fn strip_parens(e : @ast.Expr) -> @ast.Expr {
  match e.kind {
    Paren(x) => strip_parens(x)
    _ => e
  }
}

///|
/// Operator class: OR 10, AND 20, NOT 30, predicates 40, unary minus 45,
/// + - 50, * / % 60, bitwise 70 (self-parenthesized), atoms 90.
fn def_class(e : @ast.Expr) -> Int {
  match e.kind {
    Paren(x) => def_class(x)
    Or(_, _) => 10
    InList(_, items, negated~) =>
      if negated {
        30
      } else if items.length() > 1 {
        10
      } else {
        40
      }
    And(_, _) => 20
    Between(_, _, _, negated~) => if negated { 30 } else { 20 }
    Not(_) => 30
    Like(_, _, negated~, ..) => if negated { 30 } else { 40 }
    Compare(_, _, _) | IsNull(_, ..) => 40
    Unary(Neg, x) =>
      match strip_parens(x).kind {
        IntLit(_) | DecimalLit(_) | FloatLit(_) | MoneyLit(_) => 90
        _ => 45
      }
    Unary(Plus, x) => def_class(x)
    Binary(Add | Sub | ConcatSql, _, _) => 50
    Binary(Mul | Div | Mod, _, _) => 60
    Binary(BitAnd | BitOr | BitXor, _, _) => 70
    _ => 90
  }
}

///|
/// Renders `e`, parenthesized when its class is at most `max`.
fn def_wrap(e : @ast.Expr, max : Int) -> String {
  let inner = strip_parens(e)
  let text = def_expr(inner)
  if def_class(inner) <= max {
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
        Num(n) | Named(n) => n
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
/// Integer literal digits without leading zeros (captured: DEFAULT(0001)
/// is ((1))).
fn def_digits(t : String) -> String {
  let mut i = 0
  while i < t.length() - 1 && t.code_unit_at(i) == '0' {
    i += 1
  }
  t.unsafe_substring(start=i, end=t.length())
}

///|
/// Decimal literal text: `.5` prints as `0.5` (captured: msduck
/// gaps-catalog k49).
fn def_decimal(t : String) -> String {
  if t.has_prefix(".") {
    "0" + t
  } else {
    t
  }
}

///|
fn def_int(t : String) -> String {
  let d = def_digits(t)
  // integers beyond int become numeric literals: `3000000000.`
  if d.length() > 10 || (d.length() == 10 && d > "2147483647") {
    d + "."
  } else {
    d
  }
}

///|
/// Canonical datepart names (captured: dw prints as weekday).
fn def_datepart(name : String) -> String {
  match name.to_lower() {
    "yy" | "yyyy" | "year" => "year"
    "qq" | "q" | "quarter" => "quarter"
    "mm" | "m" | "month" => "month"
    "dy" | "y" | "dayofyear" => "dayofyear"
    "dd" | "d" | "day" => "day"
    "wk" | "ww" | "week" => "week"
    "dw" | "w" | "weekday" => "weekday"
    "hh" | "hour" => "hour"
    "mi" | "n" | "minute" => "minute"
    "ss" | "s" | "second" => "second"
    "ms" | "millisecond" => "millisecond"
    "mcs" | "microsecond" => "microsecond"
    "ns" | "nanosecond" => "nanosecond"
    "tz" | "tzoffset" => "tzoffset"
    "isowk" | "isoww" | "iso_week" => "iso_week"
    other => other
  }
}

///|
fn def_args(args : Array[@ast.Expr]) -> String {
  args.map(a => def_expr(strip_parens(a))).join(",")
}

///|
fn def_expr(e : @ast.Expr) -> String {
  match e.kind {
    Null => "NULL"
    Default => "DEFAULT"
    IntLit(t) => def_number(def_int(t))
    DecimalLit(t) => def_number(def_decimal(t))
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
        IntLit(t) =>
          if def_digits(t) == "0" {
            def_number("0")
          } else {
            def_number("-" + def_int(t))
          }
        DecimalLit(t) => def_number("-" + def_decimal(t))
        FloatLit(t) =>
          match @types.parse_float_text(t) {
            Some(d) => def_number(@types.format_float_scientific(-d, 17))
            None => def_number("-" + t)
          }
        _ => " -" + def_wrap(x, 89)
      }
    Unary(Plus, x) => def_expr(strip_parens(x))
    Unary(BitNot, x) => "~" + def_wrap(x, 89)
    Binary(op, l, r) => {
      let (sym, p) = match op {
        ConcatSql => ("||", 50)
        Add => ("+", 50)
        Sub => ("-", 50)
        Mul => ("*", 60)
        Div => ("/", 60)
        Mod => ("%", 60)
        BitAnd => ("&", 70)
        BitOr => ("|", 70)
        BitXor => ("^", 70)
      }
      if p == 70 {
        // bitwise operators are always parenthesized (captured)
        "(" + def_wrap(l, 60) + sym + def_wrap(r, 60) + ")"
      } else {
        def_wrap(l, p) + sym + def_wrap(r, p)
      }
    }
    Compare(op, l, r) => def_wrap(l, 50) + def_cmp(op) + def_wrap(r, 50)
    Not(x) => "NOT " + def_wrap(x, 20)
    And(l, r) => def_wrap(l, 10) + " AND " + def_wrap(r, 20)
    Or(l, r) => def_wrap(l, 0) + " OR " + def_wrap(r, 10)
    IsNull(x, negated~) =>
      def_wrap(x, 50) + (if negated { " IS NOT NULL" } else { " IS NULL" })
    Like(x, p, escape~, negated~) => {
      let base = def_wrap(x, 50) +
        " like " +
        def_wrap(p, 50) +
        (match escape {
          // captured: a space follows the escape character
          Some(esc) => " escape " + def_wrap(esc, 50) + " "
          None => ""
        })
      if negated {
        "NOT " + base
      } else {
        base
      }
    }
    Between(x, lo, hi, negated~) => {
      let base = def_wrap(x, 50) +
        ">=" +
        def_wrap(lo, 50) +
        " AND " +
        def_wrap(x, 50) +
        "<=" +
        def_wrap(hi, 50)
      if negated {
        "NOT (" + base + ")"
      } else {
        base
      }
    }
    InList(x, items, negated~) => {
      let parts = []
      for k = items.length() - 1; k >= 0; k = k - 1 {
        parts.push(def_wrap(x, 50) + "=" + def_wrap(items[k], 50))
      }
      let base = parts.join(" OR ")
      if negated && items.length() > 1 {
        "NOT (" + base + ")"
      } else if negated {
        "NOT " + base
      } else {
        base
      }
    }
    Case(operand~, whens~, else_~) => {
      let sb = StringBuilder()
      sb.write_string("case")
      match operand {
        Some(o) => sb.write_string(" " + def_expr(strip_parens(o)))
        None => ()
      }
      for w in whens {
        sb.write_string(" when " + def_expr(strip_parens(w.0)))
        sb.write_string(" then " + def_expr(strip_parens(w.1)))
      }
      match else_ {
        Some(x) => sb.write_string(" else " + def_expr(strip_parens(x)))
        // captured: two spaces before `end` without ELSE
        None => sb.write_string(" ")
      }
      sb.write_string(" end")
      sb.to_string()
    }
    Cast(x, t, try_~) =>
      if try_ {
        "TRY_CAST(" + def_expr(strip_parens(x)) + " AS " + def_type(t) + ")"
      } else {
        "CONVERT(" + def_type(t) + "," + def_expr(strip_parens(x)) + ")"
      }
    Convert(t, x, style~, try_~) =>
      match (style, try_) {
        (None, true) =>
          "TRY_CAST(" + def_expr(strip_parens(x)) + " AS " + def_type(t) + ")"
        _ =>
          (if try_ { "TRY_CONVERT(" } else { "CONVERT(" }) +
          def_type(t) +
          "," +
          def_expr(strip_parens(x)) +
          (match style {
            Some(st) => "," + def_expr(strip_parens(st))
            None => ""
          }) +
          ")"
      }
    Call(c) => {
      let n = c.name.base()
      let lower = n.to_lower()
      if c.name.parts.length() == 1 {
        match lower {
          "json_value returning" if c.args
            is [doc, path, { kind: Cast(_, ty, ..), .. }] => {
            let suffix = if ty.args.is_empty() {
              ""
            } else {
              "(" +
              ty.args
              .map(a => {
                match a {
                  Num(n) | Named(n) => n
                  Max => "max"
                }
              })
              .join(",") +
              ")"
            }
            return "json_value(" +
              def_expr(strip_parens(doc)) +
              "," +
              def_expr(strip_parens(path)) +
              " RETURNING " +
              ty.name.to_upper() +
              suffix +
              ")"
          }
          "json_query with array wrapper" =>
            return "json_query(" + def_args(c.args) + " WITH ARRAY WRAPPER)"
          "iif" if c.args.length() == 3 =>
            return "case when " +
              def_expr(strip_parens(c.args[0])) +
              " then " +
              def_expr(strip_parens(c.args[1])) +
              " else " +
              def_expr(strip_parens(c.args[2])) +
              " end"
          "year" | "month" | "day" if c.args.length() == 1 =>
            return "datepart(" + lower + "," + def_args(c.args) + ")"
          _ => ()
        }
      }
      let name = match n.to_upper() {
        "CURRENT_TIMESTAMP" => "getdate"
        "SYSTEM_USER" => "suser_sname"
        "CURRENT_USER" | "SESSION_USER" | "USER" => "user_name"
        _ =>
          if c.name.parts.length() > 1 {
            c.name.parts.map(p => "[" + p.name + "]").join(".")
          } else {
            lower
          }
      }
      if c.star {
        name + "(*)"
      } else if is_datepart_function(lower) && c.args.length() > 0 {
        let first = match strip_parens(c.args[0]).kind {
          Column([p]) => def_datepart(p.name)
          _ => def_expr(strip_parens(c.args[0]))
        }
        let rest = c.args[1:].to_owned()
        name +
        "(" +
        first +
        (if rest.is_empty() { "" } else { "," + def_args(rest) }) +
        ")"
      } else {
        name + "(" + def_args(c.args) + ")"
      }
    }
    Paren(x) => def_expr(strip_parens(x))
    Collate(x, c) => "(" + def_expr(strip_parens(x)) + ") collate " + c.name
    _ => "?"
  }
}
