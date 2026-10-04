///|
fn mk(kind : @ast.ExprKind, span : @ast.Span) -> @ast.Expr {
  { kind, span, }
}

///|
/// Search condition: OR level.
fn Parser::cond(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  let mut left = self.and_cond()
  while self.eat_kw("OR") {
    let right = self.and_cond()
    left = mk(Or(left, right), self.span_from(start))
  }
  left
}

///|
fn Parser::and_cond(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  let mut left = self.not_cond()
  while self.eat_kw("AND") {
    let right = self.not_cond()
    left = mk(And(left, right), self.span_from(start))
  }
  left
}

///|
fn Parser::not_cond(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  if self.eat_kw("NOT") {
    self.enter()
    let e = self.not_cond()
    self.leave()
    mk(Not(e), self.span_from(start))
  } else {
    self.predicate()
  }
}

///|
fn Parser::cmp_op(self : Parser) -> @ast.CmpOp? {
  let t = self.peek()
  if !(t.kind is Punct) {
    return None
  }
  match t.text {
    "=" => Some(Eq)
    "<>" | "!=" => Some(Ne)
    "<" => Some(Lt)
    "<=" => Some(Le)
    ">" => Some(Gt)
    ">=" => Some(Ge)
    "!<" => Some(NotLt)
    "!>" => Some(NotGt)
    _ => None
  }
}

///|
/// One predicate: comparison, [NOT] LIKE / BETWEEN / IN, IS [NOT] NULL,
/// EXISTS, or a bare scalar (parenthesised condition).
fn Parser::predicate(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  if self.is_kw("EXISTS") {
    self.pos += 1
    self.expect_punct("(")
    let q = self.query()
    self.expect_punct(")")
    return mk(Exists(q), self.span_from(start))
  }
  let left = self.scalar()
  if self.cmp_op() is Some(op) {
    self.pos += 1
    let quant : @ast.Quantifier? = if self.is_punct_at(1, "(") {
      if self.is_kw("ALL") {
        Some(All)
      } else if self.is_kw("ANY") {
        Some(Any)
      } else if self.is_kw("SOME") {
        Some(Some_)
      } else {
        None
      }
    } else {
      None
    }
    match quant {
      Some(qn) => {
        self.pos += 2
        let q = self.query()
        self.expect_punct(")")
        return mk(Quantified(op, qn, left, q), self.span_from(start))
      }
      None => {
        let right = self.scalar()
        return mk(Compare(op, left, right), self.span_from(start))
      }
    }
  }
  let negated = self.is_kw("NOT") &&
    (
      self.is_kw_at(1, "LIKE") ||
      self.is_kw_at(1, "IN") ||
      self.is_kw_at(1, "BETWEEN")
    )
  if negated {
    self.pos += 1
  }
  if self.eat_kw("LIKE") {
    let pat = self.scalar()
    let escape = if self.eat_kw("ESCAPE") { Some(self.scalar()) } else { None }
    mk(Like(left, pat, escape~, negated~), self.span_from(start))
  } else if self.eat_kw("BETWEEN") {
    let lo = self.scalar()
    self.expect_kw("AND")
    let hi = self.scalar()
    mk(Between(left, lo, hi, negated~), self.span_from(start))
  } else if self.eat_kw("IN") {
    self.expect_punct("(")
    if self.at_query_start() {
      let q = self.query()
      self.expect_punct(")")
      mk(InQuery(left, q, negated~), self.span_from(start))
    } else {
      let items = [self.scalar()]
      while self.eat_punct(",") {
        items.push(self.scalar())
      }
      self.expect_punct(")")
      mk(InList(left, items, negated~), self.span_from(start))
    }
  } else if self.is_kw("IS") {
    self.pos += 1
    let neg = self.eat_kw("NOT")
    self.expect_kw("NULL")
    mk(IsNull(left, negated=neg), self.span_from(start))
  } else {
    left
  }
}

///|
/// True when the current token starts a query (`SELECT`, `WITH`, or a
/// parenthesised query).
fn Parser::at_query_start(self : Parser) -> Bool {
  if self.is_kw("SELECT") || self.is_kw("WITH") {
    return true
  }
  // `((SELECT ...` : skip opening parentheses.
  let mut k = 0
  while self.is_punct_at(k, "(") {
    k += 1
  }
  k > 0 && self.is_kw_at(k, "SELECT")
}

///|
fn Parser::bin_op(self : Parser) -> (@ast.BinOp, Int)? {
  let t = self.peek()
  if !(t.kind is Punct) {
    return None
  }
  match t.text {
    "*" => Some((Mul, 2))
    "/" => Some((Div, 2))
    "%" => Some((Mod, 2))
    "+" => Some((Add, 1))
    "-" => Some((Sub, 1))
    "&" => Some((BitAnd, 1))
    "|" => Some((BitOr, 1))
    "^" => Some((BitXor, 1))
    _ => None
  }
}

///|
/// Scalar expression: arithmetic / bitwise / string operators (Pratt), no
/// comparisons or boolean operators at the top level.
fn Parser::scalar(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  self.binary(1)
}

///|
fn Parser::binary(self : Parser, min : Int) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  let mut left = self.unary()
  while self.bin_op() is Some((op, prec)) && prec >= min {
    self.pos += 1
    let right = self.binary(prec + 1)
    left = mk(Binary(op, left, right), self.span_from(start))
  }
  left
}

///|
fn Parser::unary(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  let op : @ast.UnaryOp? = if self.is_punct("-") {
    Some(Neg)
  } else if self.is_punct("+") {
    Some(Plus)
  } else if self.is_punct("~") {
    Some(BitNot)
  } else {
    None
  }
  match op {
    Some(op) => {
      self.pos += 1
      self.enter()
      let e = self.unary()
      self.leave()
      mk(Unary(op, e), self.span_from(start))
    }
    None => {
      let e = self.primary()
      self.postfix(e, start)
    }
  }
}

///|
/// COLLATE and AT TIME ZONE.
fn Parser::postfix(
  self : Parser,
  e : @ast.Expr,
  start : @ast.Span,
) -> @ast.Expr raise @ast.SyntaxError {
  let mut e = e
  while true {
    if self.is_punct(".") &&
      self.peek_at(1).kind is Word &&
      self.is_punct_at(2, "(") &&
      e.kind
      is (Var(_)
      | Paren(_)
      | Subquery(_)
      | Cast(_, _, ..)
      | Convert(_, _, ..)
      | MethodCall(_, _, _)
      | Call(_)) {
      // xml data type method: `@x.value(...)`, `(SELECT ...).query(...)`
      self.pos += 1
      let name = tok_ident(self.advance())
      let args = self.method_args()
      e = mk(MethodCall(e, name, args), self.span_from(start))
    } else if self.eat_kw("COLLATE") {
      let c = self.any_ident()
      e = mk(Collate(e, c), self.span_from(start))
    } else if self.is_kw("AT") &&
      self.is_kw_at(1, "TIME") &&
      self.is_kw_at(2, "ZONE") {
      self.pos += 3
      let zstart = self.start()
      let z = self.primary()
      let z = self.postfix_collate(z, zstart)
      e = mk(AtTimeZone(e, z), self.span_from(start))
    } else {
      break
    }
  }
  e
}

///|
fn Parser::postfix_collate(
  self : Parser,
  e : @ast.Expr,
  start : @ast.Span,
) -> @ast.Expr raise @ast.SyntaxError {
  if self.eat_kw("COLLATE") {
    let c = self.any_ident()
    mk(Collate(e, c), self.span_from(start))
  } else {
    e
  }
}

///|
/// Reserved words that are still function names directly before `(`.
fn reserved_function(word : String) -> Bool {
  match word.to_upper() {
    "LEFT" | "RIGHT" | "COALESCE" | "NULLIF" | "UPDATE" | "IDENTITY" | "USER" =>
      true
    _ => false
  }
}

///|
/// Parenless niladic functions.
fn niladic(word : String) -> Bool {
  match word.to_upper() {
    "CURRENT_TIMESTAMP"
    | "CURRENT_USER"
    | "SESSION_USER"
    | "SYSTEM_USER"
    | "USER" => true
    _ => false
  }
}

///|
fn Parser::primary(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  self.enter()
  let e = self.primary_inner()
  self.leave()
  e
}

///|
fn Parser::primary_inner(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  let t = self.peek()
  match t.kind {
    IntNum => {
      self.pos += 1
      mk(IntLit(t.text), t.span)
    }
    DecimalNum => {
      self.pos += 1
      mk(DecimalLit(t.text), t.span)
    }
    FloatNum => {
      self.pos += 1
      mk(FloatLit(t.text), t.span)
    }
    Money => {
      self.pos += 1
      mk(MoneyLit(t.text), t.span)
    }
    Str => {
      self.pos += 1
      mk(StrLit(t.text, national=false), t.span)
    }
    NStr => {
      self.pos += 1
      mk(StrLit(t.text, national=true), t.span)
    }
    BinaryLit => {
      self.pos += 1
      mk(BinaryLit(t.text), t.span)
    }
    Variable => {
      self.pos += 1
      mk(Var(t.text), t.span)
    }
    GlobalVariable => {
      self.pos += 1
      mk(GlobalVar(t.text), t.span)
    }
    Punct if t.text == "(" => self.paren_expr()
    QuotedIdent => self.name_expr()
    Word => {
      let u = upper(t)
      let next_paren = self.is_punct_at(1, "(")
      match u {
        "NULL" => {
          self.pos += 1
          mk(Null, t.span)
        }
        "CASE" => self.case_expr()
        "TRIM" if next_paren && self.trim_has_from() => {
          // TRIM([LEADING|TRAILING|BOTH] [chars] FROM s) is represented as
          // a call of TRIM / "TRIM LEADING" / "TRIM TRAILING" (s, chars);
          // chars defaults to ' '. The two-word names cannot be written as
          // an unquoted function name; they keep SQL Server's TRIM messages.
          self.pos += 2
          let fname = if self.eat_kw("LEADING") {
            "TRIM LEADING"
          } else if self.eat_kw("TRAILING") {
            "TRIM TRAILING"
          } else {
            ignore(self.eat_kw("BOTH"))
            "TRIM"
          }
          let chars = if self.is_kw("FROM") {
            mk(StrLit(" ", national=false), self.start())
          } else {
            self.scalar()
          }
          self.expect_kw("FROM")
          let s = self.scalar()
          self.expect_punct(")")
          let name : @ast.ObjectName = {
            parts: [{ name: fname, quoted: false, span: t.span, }],
            span: t.span,
          }
          mk(
            Call({
              name,
              args: [s, chars],
              distinct: false,
              star: false,
              niladic: false,
              within_group: [],
              over: None,
            }),
            self.span_from(start),
          )
        }
        "CAST" | "TRY_CAST" if next_paren => {
          self.pos += 2
          let e = self.cond()
          self.expect_kw("AS")
          let ty = self.type_name()
          self.expect_punct(")")
          mk(Cast(e, ty, try_=u == "TRY_CAST"), self.span_from(start))
        }
        "CONVERT" | "TRY_CONVERT" if next_paren => {
          self.pos += 2
          let ty = self.type_name()
          self.expect_punct(",")
          let e = self.cond()
          let style = if self.eat_punct(",") {
            Some(self.scalar())
          } else {
            None
          }
          self.expect_punct(")")
          mk(
            Convert(ty, e, style~, try_=u == "TRY_CONVERT"),
            self.span_from(start),
          )
        }
        "PARSE" | "TRY_PARSE" if next_paren => {
          self.pos += 2
          let e = self.scalar()
          self.expect_kw("AS")
          let ty = self.type_name()
          let culture = if self.eat_kw("USING") {
            Some(self.scalar())
          } else {
            None
          }
          self.expect_punct(")")
          mk(
            Parse(e, ty, culture~, try_=u == "TRY_PARSE"),
            self.span_from(start),
          )
        }
        "JSON_OBJECT" | "JSON_ARRAY" if next_paren =>
          self.json_ctor(u == "JSON_OBJECT")
        "JSON_OBJECTAGG" | "JSON_ARRAYAGG" if next_paren =>
          self.json_agg(u == "JSON_OBJECTAGG")
        "NEXT" if self.is_kw_at(1, "VALUE") && self.is_kw_at(2, "FOR") => {
          self.pos += 3
          let name = self.object_name()
          // NEXT VALUE FOR s OVER (ORDER BY ...) numbers rows in that order
          // (captured: msduck-runs sequence-reference#005,
          // tail5/b1-next-value-over); only ORDER BY is allowed
          let over = if self.is_kw("OVER") {
            let o = self.over()
            let fail = (n : Int, m : String) => {
              self.defer_error(window_error(n, 1, m, o.span))
            }
            if self.nvf_over_forbidden {
              fail(
                11717, "NEXT VALUE FOR function does not support the OVER clause in default constraints, UPDATE statements, or MERGE statements.",
              )
            } else if !o.partition_by.is_empty() {
              fail(
                11716, "NEXT VALUE FOR function does not support the PARTITION BY clause.",
              )
            } else if o.frame is Some(_) {
              fail(
                11737, "NEXT VALUE FOR function does not support the ROWS and RANGE clauses.",
              )
            } else if o.order_by.is_empty() {
              fail(
                11718, "NEXT VALUE FOR function does not support an empty OVER clause.",
              )
            }
            Some(o)
          } else {
            None
          }
          mk(NextValueFor(name, over), self.span_from(start))
        }
        _ =>
          if niladic(u) && next_paren {
            // `CURRENT_TIMESTAMP()`, `USER()`: 102 near the token after the
            // parenthesis (captured: msduck-runs tedious-compat-gaps#010,
            // tail/niladic-parentheses)
            raise near(self.peek_at(2))
          } else if niladic(u) {
            self.pos += 1
            let name : @ast.ObjectName = {
              parts: [tok_ident(t)],
              span: t.span,
            }
            mk(
              Call({
                name,
                args: [],
                distinct: false,
                star: false,
                niladic: true,
                within_group: [],
                over: None,
              }),
              t.span,
            )
          } else if is_reserved(t.text) {
            if next_paren && reserved_function(u) {
              self.pos += 1
              let name : @ast.ObjectName = {
                parts: [tok_ident(t)],
                span: t.span,
              }
              self.call(name, start)
            } else {
              raise self.error()
            }
          } else {
            self.name_expr()
          }
      }
    }
    _ => raise self.error()
  }
}

///|
/// Column reference or (possibly qualified) function call.
fn Parser::name_expr(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  let name = self.object_name()
  let n = name.parts.length()
  if self.is_punct("(") && n >= 2 && xml_method_name(name.parts[n - 1]) {
    // `col.value(...)`, `t.col.exist(...)`: an xml method on a column
    let target = name.parts[0:n - 1].to_owned()
    let tspan = { ..name.span, end: target[target.length() - 1].span.end, }
    let args = self.method_args()
    return mk(
      MethodCall(mk(Column(target), tspan), name.parts[n - 1], args),
      self.span_from(start),
    )
  }
  if self.is_punct("(") {
    self.call(name, start)
  } else {
    mk(Column(name.parts), name.span)
  }
}

///|
/// The xml data type method names (case-sensitive, as in SQL Server).
fn xml_method_name(i : @ast.Ident) -> Bool {
  !i.quoted && i.name is ("value" | "query" | "exist" | "nodes" | "modify")
}

///|
/// `( arg, ... )` of an xml method call.
fn Parser::method_args(
  self : Parser,
) -> Array[@ast.Expr] raise @ast.SyntaxError {
  self.expect_punct("(")
  let args = []
  if !self.is_punct(")") {
    args.push(self.call_arg())
    while self.eat_punct(",") {
      args.push(self.call_arg())
    }
  }
  self.expect_punct(")")
  args
}

///|
/// `( cond )`, `( query )`.
fn Parser::paren_expr(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  if self.is_kw_at(1, "SELECT") || self.is_kw_at(1, "WITH") {
    self.pos += 1
    let q = self.query()
    self.expect_punct(")")
    return mk(Subquery(q), self.span_from(start))
  }
  if self.is_punct_at(1, "(") && self.at_query_start_at(1) {
    // `((SELECT 1) UNION (SELECT 2))` or `((SELECT 1) + 1)`: try a query.
    let saved = self.pos
    let depth = self.depth
    let q : @ast.Query? = try {
      self.pos += 1
      let q = self.query()
      self.expect_punct(")")
      Some(q)
    } catch {
      _ => None
    }
    match q {
      Some(q) => return mk(Subquery(q), self.span_from(start))
      None => {
        self.pos = saved
        self.depth = depth
      }
    }
  }
  self.pos += 1
  let e = self.cond()
  self.expect_punct(")")
  mk(Paren(e), self.span_from(start))
}

///|
fn Parser::at_query_start_at(self : Parser, k : Int) -> Bool {
  let mut k = k
  while self.is_punct_at(k, "(") {
    k += 1
  }
  self.is_kw_at(k, "SELECT") || self.is_kw_at(k, "WITH")
}

///|
fn Parser::case_expr(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  self.expect_kw("CASE")
  let operand = if self.is_kw("WHEN") { None } else { Some(self.scalar()) }
  let whens = []
  while self.eat_kw("WHEN") {
    let w = if operand is Some(_) { self.scalar() } else { self.cond() }
    self.expect_kw("THEN")
    let r = self.scalar()
    whens.push((w, r))
  }
  if whens.length() == 0 {
    raise self.error()
  }
  let else_ = if self.eat_kw("ELSE") { Some(self.scalar()) } else { None }
  self.expect_kw("END")
  mk(Case(operand~, whens~, else_~), self.span_from(start))
}

///|
/// Function call after its name; current token is `(`.
fn Parser::call(
  self : Parser,
  name : @ast.ObjectName,
  start : @ast.Span,
) -> @ast.Expr raise @ast.SyntaxError {
  self.expect_punct("(")
  let mut star = false
  let mut distinct = false
  let args = []
  if self.is_punct("*") && self.is_punct_at(1, ")") && star_function(name) {
    self.pos += 1
    star = true
  } else if !self.is_punct(")") {
    if self.eat_kw("DISTINCT") {
      distinct = true
    } else if self.is_kw("ALL") && !self.is_punct_at(1, ",") {
      self.pos += 1
    }
    args.push(self.call_arg())
    // captured: STRING_AGG(DISTINCT x, ',') is 102 near ','
    if distinct && self.is_punct(",") && eq_upper_name(name, "STRING_AGG") {
      raise self.error()
    }
    while self.eat_punct(",") {
      args.push(self.call_arg())
    }
  }
  check_datepart(name, args)
  check_isjson_option(name, args)
  self.expect_punct(")")
  let within_group = if self.is_kw("WITHIN") && self.is_kw_at(1, "GROUP") {
    self.pos += 2
    self.expect_punct("(")
    self.expect_kw("ORDER")
    self.expect_kw("BY")
    let items = self.order_items()
    self.expect_punct(")")
    items
  } else {
    []
  }
  // `IGNORE NULLS` / `RESPECT NULLS` before OVER
  let nulls = if (self.is_kw("IGNORE") || self.is_kw("RESPECT")) &&
    self.is_kw_at(1, "NULLS") {
    let ignore = self.is_kw("IGNORE")
    self.pos += 2
    if !self.is_kw("OVER") {
      raise self.error()
    }
    Some(ignore)
  } else {
    None
  }
  let over = if self.is_kw("OVER") {
    let o = self.over()
    self.check_named_window_order(name, o)
    Some({ ..o, ignore_nulls: nulls.unwrap_or(false), })
  } else {
    None
  }
  mk(
    Call({ name, args, distinct, star, niladic: false, within_group, over, }),
    self.span_from(start),
  )
}

///|
fn Parser::call_arg(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  if self.is_kw("DEFAULT") {
    let t = self.advance()
    mk(Default, t.span)
  } else {
    self.cond()
  }
}

///|
fn Parser::order_items(
  self : Parser,
) -> Array[@ast.OrderItem] raise @ast.SyntaxError {
  let items = [self.order_item()]
  while self.eat_punct(",") {
    items.push(self.order_item())
  }
  items
}

///|
fn Parser::order_item(self : Parser) -> @ast.OrderItem raise @ast.SyntaxError {
  let start = self.start()
  let expr = self.scalar()
  let desc = if self.eat_kw("DESC") {
    true
  } else {
    ignore(self.eat_kw("ASC"))
    false
  }
  { expr, desc, span: self.span_from(start), }
}

///|
fn Parser::over(self : Parser) -> @ast.Over raise @ast.SyntaxError {
  let start = self.start()
  self.expect_kw("OVER")
  // `OVER w`: a named window of the SELECT (window.mbt)
  if ident_token(self.peek()) {
    let t = self.advance()
    let o = self.named_window(tok_ident(t), self.span_from(start))
    self.over_named = true
    return o
  }
  self.expect_punct("(")
  let base = self.window_base(allow_alone=false)
  let (partition_by, order_by, frame) = self.window_elements(
    frame_needs_keys=base is None,
  )
  self.expect_punct(")")
  let own : @ast.Over = {
    partition_by,
    order_by,
    frame,
    span: self.span_from(start),
    ignore_nulls: false,
  }
  match base {
    None => {
      self.over_named = false
      own
    }
    Some(b) => {
      let w = self.named_window(b, own.span)
      self.over_named = true
      match merge_window(w, own) {
        Some(m) => {
          if m.frame is Some(_) && m.order_by.is_empty() {
            self.defer_error(frame_without_order(own.span))
          }
          m
        }
        None => {
          self.defer_error(
            window_error(
              4123,
              2,
              "Window element in OVER clause can not also be specified in WINDOW clause.",
              own.span,
            ),
          )
          own
        }
      }
    }
  }
}

///|
fn Parser::frame_bound(
  self : Parser,
  start~ : Bool,
) -> @ast.FrameBound raise @ast.SyntaxError {
  if self.eat_kw("UNBOUNDED") {
    // a frame cannot start at UNBOUNDED FOLLOWING nor end at UNBOUNDED
    // PRECEDING (captured: 102 near the keyword)
    if !start && self.is_kw("PRECEDING") {
      raise self.error()
    }
    if self.eat_kw("PRECEDING") {
      UnboundedPreceding
    } else {
      if start {
        raise self.error()
      }
      self.expect_kw("FOLLOWING")
      UnboundedFollowing
    }
  } else if self.eat_kw("CURRENT") {
    self.expect_kw("ROW")
    CurrentRow
  } else {
    // offsets are unsigned integer literals up to 2147483647; variables,
    // parentheses, signs and expressions are syntax errors (captured:
    // analytic/window-frames)
    let t = self.peek()
    let ok = t.kind is IntNum &&
      (
        t.text.length() < 10 ||
        (t.text.length() == 10 && t.text <= "2147483647")
      )
    if !ok {
      raise self.error()
    }
    self.pos += 1
    let e = mk(IntLit(t.text), t.span)
    if self.eat_kw("PRECEDING") {
      Preceding(e)
    } else {
      self.expect_kw("FOLLOWING")
      Following(e)
    }
  }
}

///|
/// Syntactic type: `int`, `nvarchar(max)`, `decimal(10, 2)`, `dbo.t_name`,
/// `double precision`.
fn Parser::type_name(self : Parser) -> @ast.TypeName raise @ast.SyntaxError {
  let start = self.start()
  if self.is_kw("DOUBLE") && self.is_kw_at(1, "PRECISION") {
    self.pos += 2
    return {
      schema: None,
      name: "double precision",
      args: [],
      span: self.span_from(start),
    }
  }
  let first = if self.is_kw("CURSOR") || self.is_kw("TABLE") {
    tok_ident(self.advance())
  } else {
    self.ident()
  }
  let (schema, name) = if self.is_punct(".") {
    self.pos += 1
    (Some(first), self.any_ident())
  } else {
    (None, first)
  }
  let args : Array[@ast.TypeArg] = []
  if self.is_punct("(") {
    self.pos += 1
    while true {
      let t = self.peek()
      if t.kind is IntNum {
        self.pos += 1
        args.push(Num(t.text))
      } else if t.is_kw("MAX") {
        self.pos += 1
        args.push(Max)
      } else {
        raise self.error()
      }
      if !self.eat_punct(",") {
        break
      }
    }
    self.expect_punct(")")
  }
  { schema, name: name.name, args, span: self.span_from(start), }
}

///|
/// Functions that accept `*` as their argument.
fn star_function(name : @ast.ObjectName) -> Bool {
  name.parts.length() == 1 &&
  (match name.parts[0].name.to_upper() {
    "COUNT" | "COUNT_BIG" | "CHECKSUM" | "BINARY_CHECKSUM" => true
    _ => false
  })
}

///|
/// True when the TRIM call at the cursor uses the `... FROM s` form: a FROM
/// keyword at paren depth 1 before the closing parenthesis.
fn Parser::trim_has_from(self : Parser) -> Bool {
  let mut depth = 0
  let mut k = 1
  while true {
    let t = self.peek_at(k)
    if t.kind is Eof {
      return false
    }
    if t.is_punct("(") {
      depth += 1
    } else if t.is_punct(")") {
      depth -= 1
      if depth == 0 {
        return false
      }
    } else if depth == 1 && t.is_kw("FROM") {
      return true
    }
    k += 1
  }
  false
}
