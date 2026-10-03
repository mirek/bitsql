// The XQuery subset behind value(), query(), exist() and nodes(): location
// paths (child, descendant `//`, attribute `@`, `.`, `..`, `*`, text(),
// node(), comment(), processing-instruction()), predicates (positions,
// last(), comparisons, and/or), parenthesized filters `(path)[n]`, and a
// few functions (count, string, data, local-name, name, position, last,
// not, sum, number, contains, starts-with, string-length, concat, true,
// false). Everything else (FLWOR, namespaces declarations, arithmetic,
// sql:variable, casts) raises `Unsupported`. Static cardinality follows
// SQL Server's static typing so value() rejects non-singletons (2389).

///|
priv enum Tok {
  TName(String)
  TStr(String)
  TNum(Double)
  TPunct(String)
  TEnd
} derive(Eq)

///|
fn tok_text(t : Tok) -> String {
  match t {
    TName(s) | TPunct(s) => s
    TStr(s) => "\"" + s + "\""
    TNum(d) => d.to_string()
    TEnd => ""
  }
}

///|
fn xq_name_char(c : Int) -> Bool {
  is_name_char(c) && c != 0x3A
}

///|
fn tokenize(src : String, meth : String) -> Array[Tok] raise XmlError {
  let out : Array[Tok] = []
  let n = src.length()
  let mut i = 0
  while i < n {
    let c = src.code_unit_at(i).to_int()
    if is_ws(c) {
      i += 1
      continue
    }
    if c == 0x22 || c == 0x27 {
      let sb = StringBuilder()
      i += 1
      while true {
        if i >= n {
          raise syntax_error(meth, "")
        }
        let d = src.code_unit_at(i).to_int()
        if d == c {
          if i + 1 < n && src.code_unit_at(i + 1).to_int() == c {
            sb.write_char(c.unsafe_to_char())
            i += 2
            continue
          }
          i += 1
          break
        }
        sb.write_char(d.unsafe_to_char())
        i += 1
      }
      out.push(TStr(sb.to_string()))
      continue
    }
    if (c >= 0x30 && c <= 0x39) ||
      (
        c == 0x2E &&
        i + 1 < n &&
        src.code_unit_at(i + 1).to_int() >= 0x30 &&
        src.code_unit_at(i + 1).to_int() <= 0x39
      ) {
      let start = i
      while i < n {
        let d = src.code_unit_at(i).to_int()
        if (d >= 0x30 && d <= 0x39) || d == 0x2E {
          i += 1
        } else {
          break
        }
      }
      if i < n &&
        (
          src.code_unit_at(i).to_int() == 0x65 ||
          src.code_unit_at(i).to_int() == 0x45
        ) {
        raise Unsupported("XQuery double literals")
      }
      let text = src.unsafe_substring(start~, end=i)
      let v = @string.parse_double(text) catch {
        _ => raise syntax_error(meth, text)
      }
      out.push(TNum(v))
      continue
    }
    if is_name_start(c) && c != 0x3A {
      let start = i
      i += 1
      while i < n && xq_name_char(src.code_unit_at(i).to_int()) {
        i += 1
      }
      // QName or `prefix:*`
      if i + 1 < n &&
        src.code_unit_at(i).to_int() == 0x3A &&
        (
          is_name_start(src.code_unit_at(i + 1).to_int()) ||
          src.code_unit_at(i + 1).to_int() == 0x2A
        ) {
        i += 2
        while i < n && xq_name_char(src.code_unit_at(i).to_int()) {
          i += 1
        }
      }
      out.push(TName(src.unsafe_substring(start~, end=i)))
      continue
    }
    let two = if i + 1 < n {
      src.unsafe_substring(start=i, end=i + 2)
    } else {
      ""
    }
    if two == "//" ||
      two == ".." ||
      two == "!=" ||
      two == "<=" ||
      two == ">=" ||
      two == "::" ||
      two == "(:" {
      if two == "(:" {
        raise Unsupported("XQuery comments")
      }
      out.push(TPunct(two))
      i += 2
      continue
    }
    match c {
      0x2F
      | 0x28
      | 0x29
      | 0x5B
      | 0x5D
      | 0x40
      | 0x2E
      | 0x2A
      | 0x2C
      | 0x3D
      | 0x3C
      | 0x3E
      | 0x2B
      | 0x2D
      | 0x24
      | 0x3B
      | 0x7B
      | 0x7D
      | 0x7C
      | 0x3A => {
        out.push(TPunct(c.unsafe_to_char().to_string()))
        i += 1
      }
      _ => raise syntax_error(meth, c.unsafe_to_char().to_string())
    }
  }
  out.push(TEnd)
  out
}

///|
fn syntax_error(meth : String, near : String) -> XmlError {
  Sql(2209, 1, "XQuery [\{meth}()]: Syntax error near '\{near}'")
}

///|
priv enum Axis {
  Child
  Desc
  DescAttr
  AttrAxis
  SelfAxis
  Parent
} derive(Debug)

///|
priv enum Test {
  Named(String)
  Wild
  TextTest
  NodeTest
  CommentTest
  PiTest
} derive(Debug)

///|
priv struct Step {
  axis : Axis
  ntest : Test
  preds : Array[XExpr]
} derive(Debug)

///|
priv enum XExpr {
  Root
  Ctx
  Path(XExpr, Array[Step])
  Filter(XExpr, Array[XExpr])
  Lit(String)
  Num(Double)
  Fn(String, Array[XExpr])
  /// sql:variable / sql:column value number i
  Ext(Int)
  Cmp(String, XExpr, XExpr)
  Arith(String, XExpr, XExpr)
  And(XExpr, XExpr)
  Or(XExpr, XExpr)
} derive(Debug)

///|
/// A compiled XQuery expression for one xml meth call.
pub struct XPath {
  priv expr : XExpr
  meth : String
  /// sql:variable("@v") / sql:column("t.c") references in order of first
  /// use: (is_column, name); their values are passed to evaluation.
  externals : Array[(Bool, String)]
} derive(Debug)

///|
/// A sql:variable / sql:column value as XQuery sees it.
pub(all) enum Ext {
  ExtNull
  ExtNum(Double)
  ExtStr(String)
  ExtBool(Bool)
} derive(Debug)

///|
pub fn XPath::externals(self : XPath) -> Array[(Bool, String)] {
  self.externals
}

///|
priv struct XParser {
  toks : Array[Tok]
  mut pos : Int
  meth : String
  externals : Array[(Bool, String)]
}

///|
fn XParser::peek(self : XParser) -> Tok {
  self.toks[self.pos]
}

///|
fn XParser::peek_at(self : XParser, k : Int) -> Tok {
  let i = self.pos + k
  if i < self.toks.length() {
    self.toks[i]
  } else {
    TEnd
  }
}

///|
fn XParser::is_punct(self : XParser, p : String) -> Bool {
  self.peek() == TPunct(p)
}

///|
fn XParser::fail(self : XParser) -> XmlError {
  syntax_error(self.meth, tok_text(self.peek()))
}

///|
fn XParser::expect(self : XParser, p : String) -> Unit raise XmlError {
  if !self.is_punct(p) {
    raise self.fail()
  }
  self.pos += 1
}

///|
let unsupported_words : Array[String] = [
  "for", "let", "if", "some", "every", "declare", "typeswitch", "element", "attribute",
  "document", "validate", "ordered", "unordered", "xquery",
]

///|
/// Compiles `src` for `meth` ("value", "query", "exist", "nodes").
pub fn compile(src : String, meth : String) -> XPath raise XmlError {
  let toks = tokenize(src, meth)
  for t in toks {
    match t {
      TPunct("$") => raise Unsupported("XQuery variables and FLWOR expressions")
      TPunct("{" | "}") => raise Unsupported("XQuery constructors")
      TPunct("|") => raise Unsupported("XQuery union operator")
      TPunct("::") => raise Unsupported("XQuery explicit axes")
      _ => ()
    }
  }
  match toks[0] {
    TName(w) if unsupported_words.contains(w) &&
      !(toks[1] is TPunct("/" | "//" | "[" | "(") || toks[1] == TEnd) =>
      raise Unsupported("XQuery '\{w}' expressions")
    _ => ()
  }
  let p : XParser = { toks, pos: 0, meth, externals: [], }
  if p.peek() == TEnd {
    raise syntax_error(meth, "")
  }
  let e = p.or_expr()
  match p.peek() {
    TEnd => ()
    TPunct("+" | "-" | "*") => raise Unsupported("XQuery arithmetic")
    TName("div" | "mod" | "idiv") => raise Unsupported("XQuery arithmetic")
    TName("cast" | "castable" | "instance" | "treat" | "to") =>
      raise Unsupported("XQuery '\{tok_text(p.peek())}' expressions")
    TName("eq" | "ne" | "lt" | "le" | "gt" | "ge" | "is") =>
      raise Unsupported("XQuery value comparisons")
    TPunct(",") => raise Unsupported("XQuery sequence expressions")
    _ => raise p.fail()
  }
  check_function_args(meth, e)
  { expr: e, meth, externals: p.externals, }
}

///|
fn XParser::or_expr(self : XParser) -> XExpr raise XmlError {
  let mut e = self.and_expr()
  while self.peek() == TName("or") {
    self.pos += 1
    e = Or(e, self.and_expr())
  }
  e
}

///|
fn XParser::and_expr(self : XParser) -> XExpr raise XmlError {
  let mut e = self.cmp_expr()
  while self.peek() == TName("and") {
    self.pos += 1
    e = And(e, self.cmp_expr())
  }
  e
}

///|
fn XParser::cmp_expr(self : XParser) -> XExpr raise XmlError {
  let e = self.add_expr()
  match self.peek() {
    TPunct("=" | "!=" | "<" | "<=" | ">" | ">=" as op) => {
      self.pos += 1
      Cmp(op.to_string(), e, self.add_expr())
    }
    TName("eq" | "ne" | "lt" | "le" | "gt" | "ge") =>
      raise Unsupported("XQuery value comparisons")
    _ => e
  }
}

///|
/// `a + b`, `a - b` (XQuery arithmetic on atomized operands).
fn XParser::add_expr(self : XParser) -> XExpr raise XmlError {
  let mut e = self.mul_expr()
  while true {
    match self.peek() {
      TPunct("+" | "-" as op) => {
        self.pos += 1
        e = Arith(op.to_string(), e, self.mul_expr())
      }
      _ => break
    }
  }
  e
}

///|
fn XParser::mul_expr(self : XParser) -> XExpr raise XmlError {
  let mut e = self.unary_expr()
  while true {
    let op = match self.peek() {
      TPunct("*") => "*"
      TName("div" | "mod" | "idiv" as w) => w.to_string()
      _ => break
    }
    self.pos += 1
    e = Arith(op, e, self.unary_expr())
  }
  e
}

///|
fn XParser::unary_expr(self : XParser) -> XExpr raise XmlError {
  if self.is_punct("-") {
    self.pos += 1
    return Arith("-", Num(0.0), self.unary_expr())
  }
  if self.is_punct("+") {
    self.pos += 1
    return self.unary_expr()
  }
  self.path_expr()
}

///|
fn kind_test(name : String) -> Test? {
  match name {
    "text" => Some(TextTest)
    "node" => Some(NodeTest)
    "comment" => Some(CommentTest)
    "processing-instruction" => Some(PiTest)
    _ => None
  }
}

///|
fn XParser::starts_step(self : XParser) -> Bool {
  match self.peek() {
    TPunct("@" | "." | ".." | "*") => true
    TName(n) =>
      // a name followed by '(' is a function call unless it is a kind test
      !(self.peek_at(1) == TPunct("(")) || kind_test(n) is Some(_)
    _ => false
  }
}

///|
fn XParser::path_expr(self : XParser) -> XExpr raise XmlError {
  if self.is_punct("/") {
    self.pos += 1
    if self.starts_step() {
      return Path(Root, self.rel_steps(Child))
    }
    return Root
  }
  if self.is_punct("//") {
    self.pos += 1
    return Path(Root, self.rel_steps(Desc))
  }
  if self.starts_step() {
    return Path(Ctx, self.rel_steps(Child))
  }
  let base = self.filter_expr()
  if self.is_punct("/") || self.is_punct("//") {
    let axis : Axis = if self.is_punct("//") { Desc } else { Child }
    self.pos += 1
    return Path(base, self.rel_steps(axis))
  }
  base
}

///|
fn XParser::rel_steps(
  self : XParser,
  first : Axis,
) -> Array[Step] raise XmlError {
  let steps = [self.step(first)]
  while self.is_punct("/") || self.is_punct("//") {
    let axis : Axis = if self.is_punct("//") { Desc } else { Child }
    self.pos += 1
    steps.push(self.step(axis))
  }
  steps
}

///|
fn XParser::name_test(self : XParser) -> Test raise XmlError {
  match self.peek() {
    TPunct("*") => {
      self.pos += 1
      Wild
    }
    TName(n) => {
      if n.contains(":") {
        raise Unsupported("XQuery namespace prefixes")
      }
      self.pos += 1
      Named(n)
    }
    _ => raise self.fail()
  }
}

///|
fn XParser::step(self : XParser, axis : Axis) -> Step raise XmlError {
  let (axis, ntest) = match self.peek() {
    TPunct(".") => {
      self.pos += 1
      if axis is Desc {
        raise Unsupported("XQuery '//.'")
      }
      (SelfAxis, NodeTest)
    }
    TPunct("..") => {
      self.pos += 1
      if axis is Desc {
        raise Unsupported("XQuery '//..'")
      }
      (Parent, NodeTest)
    }
    TPunct("@") => {
      self.pos += 1
      let t = self.name_test()
      (if axis is Desc { DescAttr } else { AttrAxis }, t)
    }
    TName(n) if self.peek_at(1) == TPunct("(") =>
      match kind_test(n) {
        Some(t) => {
          self.pos += 2
          if t is PiTest && !self.is_punct(")") {
            raise Unsupported("processing-instruction() with a target")
          }
          self.expect(")")
          (axis, t)
        }
        None => raise self.fail()
      }
    _ => (axis, self.name_test())
  }
  { axis, ntest, preds: self.predicates(), }
}

///|
fn XParser::predicates(self : XParser) -> Array[XExpr] raise XmlError {
  let preds = []
  while self.is_punct("[") {
    self.pos += 1
    if self.is_punct("]") {
      raise self.fail()
    }
    preds.push(self.or_expr())
    self.expect("]")
  }
  preds
}

///|
let known_functions : Array[String] = [
  "count", "string", "data", "local-name", "position", "last", "not", "sum", "number",
  "contains", "starts-with", "string-length", "concat", "true", "false", "boolean",
]

///|
fn XParser::filter_expr(self : XParser) -> XExpr raise XmlError {
  let prim = match self.peek() {
    TStr(s) => {
      self.pos += 1
      Lit(s)
    }
    TNum(d) => {
      self.pos += 1
      Num(d)
    }
    TPunct("(") => {
      self.pos += 1
      if self.is_punct(")") {
        raise Unsupported("XQuery empty sequences")
      }
      let e = self.or_expr()
      if self.is_punct(",") {
        raise Unsupported("XQuery sequence expressions")
      }
      self.expect(")")
      e
    }
    TName(n) if self.peek_at(1) == TPunct("(") => {
      if n == "sql:variable" || n == "sql:column" {
        self.pos += 2
        let name = match self.peek() {
          TStr(v) => v
          _ => raise self.fail()
        }
        self.pos += 1
        self.expect(")")
        let key = (n == "sql:column", name)
        let mut idx = -1
        for i, k in self.externals {
          if k.0 == key.0 && k.1.to_lower() == key.1.to_lower() {
            idx = i
          }
        }
        if idx < 0 {
          idx = self.externals.length()
          self.externals.push(key)
        }
        return Ext(idx)
      }
      if n == "name" || n == "fn:name" {
        // captured: SQL Server has no fn:name() (2395)
        raise Sql(
          2395,
          1,
          "XQuery [\{self.meth}()]: There is no function '{http://www.w3.org/2004/07/xpath-functions}:name()'",
        )
      }
      if !known_functions.contains(n) {
        raise Unsupported("XQuery function \{n}()")
      }
      self.pos += 2
      let args = []
      if !self.is_punct(")") {
        args.push(self.or_expr())
        while self.is_punct(",") {
          self.pos += 1
          args.push(self.or_expr())
        }
      }
      self.expect(")")
      Fn(n, args)
    }
    _ => raise self.fail()
  }
  let preds = self.predicates()
  if preds.is_empty() {
    prim
  } else {
    Filter(prim, preds)
  }
}

// ------------------------------------------------------- static typing

///|
priv enum Card {
  One
  Opt
  Many
}

///|
fn card_mul(a : Card, b : Card) -> Card {
  match (a, b) {
    (Many, _) | (_, Many) => Many
    (One, One) => One
    _ => Opt
  }
}

///|
fn positional(preds : Array[XExpr]) -> Bool {
  preds.iter().any(p => p is (Num(_) | Fn("last", [])))
}

///|
fn static_card(e : XExpr) -> Card {
  match e {
    Root
    | Ctx
    | Lit(_)
    | Num(_)
    | Cmp(_, _, _)
    | And(_, _)
    | Or(_, _)
    | Ext(_) => One
    // an empty operand gives an empty result
    Arith(_, a, b) =>
      if static_card(a) is Many || static_card(b) is Many {
        Many
      } else {
        Opt
      }
    Fn("data", [a]) => static_card(a)
    Fn(_, _) => One
    Filter(inner, preds) =>
      if positional(preds) {
        Opt
      } else {
        card_mul(static_card(inner), Opt)
      }
    Path(base, steps) => {
      let mut c = static_card(base)
      for s in steps {
        let step_card = match s.axis {
          AttrAxis => if s.ntest is Named(_) { Opt } else { Many }
          SelfAxis => if s.preds.is_empty() { One } else { Opt }
          Parent => Opt
          Child | Desc | DescAttr =>
            if positional(s.preds) {
              Opt
            } else {
              Many
            }
        }
        c = card_mul(c, step_card)
      }
      c
    }
  }
}

///|
/// The static type SQL Server names in 2389 for a path's last step.
fn static_type_text(e : XExpr) -> String {
  match e {
    Path(_, steps) => {
      let s = steps[steps.length() - 1]
      match (s.axis, s.ntest) {
        (AttrAxis | DescAttr, Named(n)) => "attribute(\{n},xdt:untypedAtomic) *"
        (AttrAxis | DescAttr, _) => "attribute(*,xdt:untypedAtomic) *"
        (_, Named(n)) => "element(\{n},xdt:untyped) *"
        (_, Wild) => "element(*,xdt:untyped) *"
        (_, TextTest) => "text() *"
        _ => "node() *"
      }
    }
    Filter(inner, _) => static_type_text(inner)
    _ => "xdt:untypedAtomic *"
  }
}

///|
/// Functions taking one item reject a possibly longer sequence at compile
/// time (captured: string(/a/@x) is 2389).
fn check_function_args(meth : String, e : XExpr) -> Unit raise XmlError {
  match e {
    Fn(name, args) => {
      if name is ("string" | "local-name" | "number" | "string-length") &&
        args.length() == 1 &&
        static_card(args[0]) is Many {
        raise Sql(
          2389,
          1,
          "XQuery [\{meth}()]: '\{name}()' requires a singleton (or empty sequence), found operand of type '\{static_type_text(args[0])}'",
        )
      }
      for a in args {
        check_function_args(meth, a)
      }
    }
    Path(base, steps) => {
      check_function_args(meth, base)
      for st in steps {
        for p in st.preds {
          check_function_args(meth, p)
        }
      }
    }
    Filter(inner, preds) => {
      check_function_args(meth, inner)
      for p in preds {
        check_function_args(meth, p)
      }
    }
    Cmp(_, a, b) | And(a, b) | Or(a, b) | Arith(_, a, b) => {
      check_function_args(meth, a)
      check_function_args(meth, b)
    }
    _ => ()
  }
}

///|
/// value(): the expression must be a singleton (captured 2389).
pub fn XPath::check_singleton(self : XPath) -> Unit raise XmlError {
  if static_card(self.expr) is Many {
    raise Sql(
      2389, 1, "XQuery [value()]: 'value()' requires a singleton (or empty sequence), found operand of type 'xdt:untypedAtomic *'",
    )
  }
}

///|
fn ends_in_attribute(e : XExpr) -> Bool {
  match e {
    Path(_, steps) => steps[steps.length() - 1].axis is (AttrAxis | DescAttr)
    Filter(inner, _) => ends_in_attribute(inner)
    _ => false
  }
}

///|
/// query(): attributes cannot be returned at the top level (captured 2396).
pub fn XPath::check_query(self : XPath) -> Unit raise XmlError {
  if ends_in_attribute(self.expr) {
    raise Sql(
      2396, 1, "XQuery [query()]: Attribute may not appear outside of an element",
    )
  }
}

// ------------------------------------------------------------ evaluation

///|
/// A node in the document: `node` is the node at `path` (the owning
/// element for attributes, `attr` >= 0).
priv struct NRef {
  node : Node
  path : Array[Int]
  attr : Int
}

///|
priv enum Item {
  N(NRef)
  S(String)
  D(Double)
  /// xs:integer (count, position, integer literals)
  I(Int64)
  B(Bool)
}

///|
let doc_name : QName = { prefix: "", lname: "", ns: "#document", }

///|
fn doc_root(x : Xml) -> NRef {
  { node: Element(doc_name, [], x.nodes), path: [], attr: -1, }
}

///|
fn is_doc(r : NRef) -> Bool {
  r.path.is_empty() && r.attr < 0
}

///|
fn resolve(x : Xml, path : Array[Int], attr : Int) -> NRef {
  let mut node : Node = Element(doc_name, [], x.nodes)
  for i in path {
    match node {
      Element(_, _, children) if i < children.length() => node = children[i]
      _ => ()
    }
  }
  { node, path, attr, }
}

///|
fn context_of(x : Xml) -> NRef {
  resolve(x, x.path, x.attr)
}

///|
fn children_of(r : NRef) -> Array[NRef] {
  if r.attr >= 0 {
    return []
  }
  match r.node {
    Element(_, _, children) =>
      children.mapi((i, c) => { node: c, path: r.path + [i], attr: -1, })
    _ => []
  }
}

///|
fn attrs_of(r : NRef) -> Array[(NRef, Attr)] {
  if r.attr >= 0 {
    return []
  }
  match r.node {
    Element(_, attrs, _) =>
      attrs.mapi((i, a) => ({ node: r.node, path: r.path, attr: i, }, a))
    _ => []
  }
}

///|
fn the_attr(r : NRef) -> Attr? {
  match r.node {
    Element(_, attrs, _) if r.attr >= 0 && r.attr < attrs.length() =>
      Some(attrs[r.attr])
    _ => None
  }
}

///|
fn test_matches(t : Test, r : NRef) -> Bool {
  match (t, r.node) {
    (Named(n), Element(q, _, _)) => q.ns == "" && q.lname == n
    (Wild, Element(_, _, _)) => true
    (TextTest, Text(_)) => true
    (CommentTest, Comment(_)) => true
    (PiTest, Pi(_, _)) => true
    (NodeTest, _) => true
    _ => false
  }
}

///|
fn attr_matches(t : Test, a : Attr) -> Bool {
  if a.is_namespace_decl() {
    return false
  }
  match t {
    Named(n) => a.name.ns == "" && a.name.lname == n
    Wild | NodeTest => true
    _ => false
  }
}

///|
fn descendants(r : NRef, out : Array[NRef]) -> Unit {
  for c in children_of(r) {
    out.push(c)
    descendants(c, out)
  }
}

///|
fn parent_of(x : Xml, r : NRef) -> NRef? {
  if r.attr >= 0 {
    return Some({ ..r, attr: -1, })
  }
  if r.path.is_empty() {
    return None
  }
  let p = r.path[0:r.path.length() - 1].to_owned()
  Some(resolve(x, p, -1))
}

///|
fn string_value(r : NRef) -> String {
  match the_attr(r) {
    Some(a) => a.value
    None =>
      match r.node {
        Text(s) | Comment(s) => s
        Pi(_, d) => d
        Element(_, _, _) => {
          let sb = StringBuilder()
          collect_text(r.node, sb)
          sb.to_string()
        }
      }
  }
}

///|
fn collect_text(n : Node, sb : StringBuilder) -> Unit {
  match n {
    Text(s) => sb.write_string(s)
    Element(_, _, children) =>
      for c in children {
        collect_text(c, sb)
      }
    _ => ()
  }
}

///|
fn compare_order(a : NRef, b : NRef) -> Int {
  let n = if a.path.length() < b.path.length() {
    a.path.length()
  } else {
    b.path.length()
  }
  for i in 0..<n {
    if a.path[i] != b.path[i] {
      return a.path[i] - b.path[i]
    }
  }
  if a.path.length() != b.path.length() {
    // an ancestor (shorter path) comes first, its attributes too
    if a.path.length() < b.path.length() {
      -1
    } else {
      1
    }
  } else {
    a.attr - b.attr
  }
}

///|
fn doc_order(nodes : Array[NRef]) -> Array[NRef] {
  let sorted = nodes.copy()
  sorted.sort_by((a, b) => compare_order(a, b))
  let out : Array[NRef] = []
  for r in sorted {
    match out.last() {
      Some(l) if compare_order(l, r) == 0 => ()
      _ => out.push(r)
    }
  }
  out
}

///|
priv struct Env {
  x : Xml
  ctx : NRef
  pos : Int
  size : Int
  ext : Array[Ext]
}

///|
fn atomize(items : Array[Item]) -> Array[Item] {
  items.map(i => {
    match i {
      N(r) => S(string_value(r))
      other => other
    }
  })
}

///|
fn ebv(items : Array[Item]) -> Bool {
  match items {
    [] => false
    [B(b)] => b
    [S(s)] => s != ""
    [D(d)] => d != 0.0 && !d.is_nan()
    [I(n)] => n != 0L
    _ => true
  }
}

///|
fn to_number(s : String) -> Double? {
  let t = s.trim().to_owned()
  if t == "" {
    return None
  }
  for i in 0..<t.length() {
    let c = t.code_unit_at(i).to_int()
    if !((c >= 0x30 && c <= 0x39) ||
      c == 0x2E ||
      c == 0x2D ||
      c == 0x2B ||
      c == 0x65 ||
      c == 0x45) {
      return None
    }
  }
  try @string.parse_double(t) catch {
    _ => None
  } noraise {
    v => Some(v)
  }
}

///|
fn item_number(i : Item) -> Double? {
  match i {
    D(d) => Some(d)
    I(n) => Some(n.to_double())
    S(s) => to_number(s)
    B(b) => Some(if b { 1.0 } else { 0.0 })
    N(r) => to_number(string_value(r))
  }
}

///|
fn item_string(i : Item) -> String {
  match i {
    S(s) => s
    D(d) => format_number(d)
    I(n) => n.to_string()
    B(b) => if b { "true" } else { "false" }
    N(r) => string_value(r)
  }
}

///|
fn format_number(d : Double) -> String {
  // captured (xml/more#009 probe): sum() of nothing is "0.0E0", integral
  // doubles print as integers, others in shortest form ("2.5")
  if d == 0.0 {
    "0.0E0"
  } else if d == d.floor() && d.abs() < 1.0e15 {
    d.to_int64().to_string()
  } else {
    d.to_string()
  }
}

///|
fn cmp_holds(op : String, c : Int) -> Bool {
  match op {
    "=" => c == 0
    "!=" => c != 0
    "<" => c < 0
    "<=" => c <= 0
    ">" => c > 0
    _ => c >= 0
  }
}

///|
fn general_compare(op : String, a : Array[Item], b : Array[Item]) -> Bool {
  for x in atomize(a) {
    for y in atomize(b) {
      let numeric = x is (D(_) | I(_) | B(_)) || y is (D(_) | I(_) | B(_))
      if numeric {
        match (item_number(x), item_number(y)) {
          (Some(p), Some(q)) =>
            if cmp_holds(op, if p < q { -1 } else if p > q { 1 } else { 0 }) {
              return true
            }
          _ => ()
        }
      } else if cmp_holds(op, item_string(x).compare(item_string(y))) {
        return true
      }
    }
  }
  false
}

///|
/// XQuery arithmetic: empty operands give the empty sequence; untyped
/// values are cast to xs:double; integer operands stay integers except
/// for `div`.
fn arith(
  op : String,
  a : Array[Item],
  b : Array[Item],
) -> Array[Item] raise XmlError {
  let x = match atomize(a) {
    [] => return []
    [x] => x
    _ => raise Unsupported("XQuery arithmetic on sequences")
  }
  let y = match atomize(b) {
    [] => return []
    [y] => y
    _ => raise Unsupported("XQuery arithmetic on sequences")
  }
  match (x, y) {
    (I(p), I(q)) if op != "div" =>
      match op {
        "+" => return [I(p + q)]
        "-" => return [I(p - q)]
        "*" => return [I(p * q)]
        _ =>
          if q == 0L {
            raise Unsupported("XQuery division by zero")
          } else if op == "mod" {
            return [I(p % q)]
          } else {
            return [I(p / q)]
          }
      }
    _ => ()
  }
  let (p, q) = match (item_number(x), item_number(y)) {
    (Some(p), Some(q)) => (p, q)
    _ => raise Unsupported("XQuery arithmetic on non-numeric values")
  }
  let r = match op {
    "+" => p + q
    "-" => p - q
    "*" => p * q
    "div" => p / q
    "idiv" => (p / q).floor()
    _ => p - (p / q).floor() * q
  }
  [D(r)]
}

///|
fn eval(env : Env, e : XExpr) -> Array[Item] raise XmlError {
  match e {
    Root => [N(doc_root(env.x))]
    Ctx => [N(env.ctx)]
    Lit(s) => [S(s)]
    Num(d) =>
      if d == d.floor() && d.abs() < 1.0e18 {
        [I(d.to_int64())]
      } else {
        [D(d)]
      }
    And(a, b) => [B(ebv(eval(env, a)) && ebv(eval(env, b)))]
    Or(a, b) => [B(ebv(eval(env, a)) || ebv(eval(env, b)))]
    Cmp(op, a, b) => [B(general_compare(op, eval(env, a), eval(env, b)))]
    Arith(op, a, b) => arith(op, eval(env, a), eval(env, b))
    Filter(inner, preds) => {
      let mut items = eval(env, inner)
      for p in preds {
        items = filter_items(env, items, p)
      }
      items
    }
    Path(base, steps) => {
      let mut cur : Array[NRef] = []
      for i in eval(env, base) {
        match i {
          N(r) => cur.push(r)
          _ =>
            raise Sql(2389, 1, "XQuery [\{env.x.attr}]: path steps need nodes")
        }
      }
      for s in steps {
        let next : Array[NRef] = []
        for r in cur {
          let cands : Array[NRef] = match s.axis {
            Child => children_of(r).filter(c => test_matches(s.ntest, c))
            Desc => {
              let all = []
              descendants(r, all)
              all.filter(c => test_matches(s.ntest, c))
            }
            DescAttr => {
              let all = [r]
              descendants(r, all)
              let out = []
              for d in all {
                for pair in attrs_of(d) {
                  if attr_matches(s.ntest, pair.1) {
                    out.push(pair.0)
                  }
                }
              }
              out
            }
            AttrAxis =>
              attrs_of(r).filter(p => attr_matches(s.ntest, p.1)).map(p => p.0)
            SelfAxis => [r]
            Parent =>
              match parent_of(env.x, r) {
                Some(p) => [p]
                None => []
              }
          }
          let mut items : Array[Item] = cands.map(c => N(c))
          for p in s.preds {
            items = filter_items(env, items, p)
          }
          for it in items {
            if it is N(n) {
              next.push(n)
            }
          }
        }
        cur = if cur.length() > 1 { doc_order(next) } else { next }
      }
      cur.map(r => N(r))
    }
    Fn(name, args) => call(env, name, args)
    Ext(i) =>
      match env.ext.get(i) {
        Some(ExtNum(d)) => [D(d)]
        Some(ExtStr(s)) => [S(s)]
        Some(ExtBool(b)) => [B(b)]
        _ => []
      }
  }
}

///|
fn filter_items(
  env : Env,
  items : Array[Item],
  pred : XExpr,
) -> Array[Item] raise XmlError {
  let out = []
  let size = items.length()
  for i, it in items {
    let ctx = match it {
      N(r) => r
      _ => env.ctx
    }
    let v = eval({ x: env.x, ctx, pos: i + 1, size, ext: env.ext, }, pred)
    let keep = match v {
      [D(d)] => d == (i + 1).to_double()
      [I(n)] => n == (i + 1).to_int64()
      _ => ebv(v)
    }
    if keep {
      out.push(it)
    }
  }
  out
}

///|
fn opt_node(env : Env, args : Array[XExpr]) -> NRef? raise XmlError {
  if args.is_empty() {
    return Some(env.ctx)
  }
  match eval(env, args[0]) {
    [] => None
    [N(r), ..] => Some(r)
    _ => None
  }
}

///|
fn call(
  env : Env,
  name : String,
  args : Array[XExpr],
) -> Array[Item] raise XmlError {
  let arity = fn(n : Int) raise XmlError {
    if args.length() != n {
      raise Unsupported("XQuery \{name}() with \{args.length()} arguments")
    }
  }
  match name {
    "count" => {
      arity(1)
      [I(eval(env, args[0]).length().to_int64())]
    }
    "last" => {
      arity(0)
      [I(env.size.to_int64())]
    }
    "position" => {
      arity(0)
      [I(env.pos.to_int64())]
    }
    "true" => {
      arity(0)
      [B(true)]
    }
    "false" => {
      arity(0)
      [B(false)]
    }
    "not" => {
      arity(1)
      [B(!ebv(eval(env, args[0])))]
    }
    "boolean" => {
      arity(1)
      [B(ebv(eval(env, args[0])))]
    }
    "data" => {
      arity(1)
      atomize(eval(env, args[0]))
    }
    "string" => {
      if args.length() > 1 {
        arity(1)
      }
      let v = if args.is_empty() { [N(env.ctx)] } else { eval(env, args[0]) }
      match v {
        [] => [S("")]
        [i, ..] => [S(item_string(i))]
      }
    }
    "string-length" => {
      if args.length() > 1 {
        arity(1)
      }
      let v = if args.is_empty() { [N(env.ctx)] } else { eval(env, args[0]) }
      let s = match v {
        [] => ""
        [i, ..] => item_string(i)
      }
      [I(s.length().to_int64())]
    }
    "number" => {
      if args.length() > 1 {
        arity(1)
      }
      let v = if args.is_empty() { [N(env.ctx)] } else { eval(env, args[0]) }
      match v {
        [i, ..] => [D(item_number(i).unwrap_or(@double.not_a_number))]
        [] => [D(@double.not_a_number)]
      }
    }
    "sum" => {
      arity(1)
      let mut t = 0.0
      for i in eval(env, args[0]) {
        match item_number(i) {
          Some(d) => t += d
          None => raise Unsupported("XQuery sum() of non-numeric values")
        }
      }
      [D(t)]
    }
    "local-name" | "name" => {
      if args.length() > 1 {
        arity(1)
      }
      match opt_node(env, args) {
        None => [S("")]
        Some(r) =>
          match the_attr(r) {
            Some(a) =>
              [S(if name == "name" { a.name.text() } else { a.name.lname })]
            None =>
              match r.node {
                Element(q, _, _) if !is_doc(r) =>
                  [S(if name == "name" { q.text() } else { q.lname })]
                Pi(t, _) => [S(t)]
                _ => [S("")]
              }
          }
      }
    }
    "contains" | "starts-with" => {
      arity(2)
      let a = match eval(env, args[0]) {
        [] => ""
        [i, ..] => item_string(i)
      }
      let b = match eval(env, args[1]) {
        [] => ""
        [i, ..] => item_string(i)
      }
      [B(if name == "contains" { a.contains(b) } else { a.has_prefix(b) })]
    }
    "concat" => {
      let sb = StringBuilder()
      for a in args {
        match eval(env, a) {
          [] => ()
          [i, ..] => sb.write_string(item_string(i))
        }
      }
      [S(sb.to_string())]
    }
    _ => raise Unsupported("XQuery function \{name}()")
  }
}

///|
fn run(x : Xml, p : XPath, ext : Array[Ext]) -> Array[Item] raise XmlError {
  let ctx = context_of(x)
  eval({ x, ctx, pos: 1, size: 1, ext, }, p.expr)
}

///|
/// value(): the atomized singleton as text, None for the empty sequence.
pub fn value(
  x : Xml,
  p : XPath,
  ext? : Array[Ext] = [],
) -> String? raise XmlError {
  match run(x, p, ext) {
    [] => None
    [i] => Some(item_string(i))
    _ =>
      raise Sql(
        2389, 1, "XQuery [value()]: 'value()' requires a singleton (or empty sequence), found operand of type 'xdt:untypedAtomic *'",
      )
  }
}

///|
/// exist(): is the result non-empty? (A boolean result counts by value.)
pub fn exist(x : Xml, p : XPath, ext? : Array[Ext] = []) -> Bool raise XmlError {
  match run(x, p, ext) {
    [] => false
    [B(b)] => b
    _ => true
  }
}

///|
/// query(): the result sequence as a new untyped xml fragment; adjacent
/// atomic values are separated by a space.
pub fn query(x : Xml, p : XPath, ext? : Array[Ext] = []) -> Xml raise XmlError {
  let out : Array[Node] = []
  let mut prev_atomic = false
  for i in run(x, p, ext) {
    match i {
      N(r) => {
        prev_atomic = false
        if r.attr >= 0 {
          raise Sql(
            2396, 1, "XQuery [query()]: Attribute may not appear outside of an element",
          )
        }
        if is_doc(r) {
          match r.node {
            Element(_, _, children) =>
              for c in children {
                out.push(c)
              }
            _ => ()
          }
        } else {
          out.push(r.node)
        }
      }
      other => {
        let s = item_string(other)
        let t = if prev_atomic { " " + s } else { s }
        match out.last() {
          Some(Text(prev)) if prev_atomic =>
            out[out.length() - 1] = Text(prev + t)
          _ => out.push(Text(t))
        }
        prev_atomic = true
      }
    }
  }
  // drop empty text produced by empty strings
  Xml::of_nodes(out.filter(n => !(n is Text(""))))
}

///|
/// nodes(): one context reference per result node.
pub fn nodes(
  x : Xml,
  p : XPath,
  ext? : Array[Ext] = [],
) -> Array[Xml] raise XmlError {
  let out = []
  for i in run(x, p, ext) {
    match i {
      N(r) => out.push({ nodes: x.nodes, path: r.path, attr: r.attr, })
      _ => raise Unsupported("nodes() over atomic values")
    }
  }
  out
}
