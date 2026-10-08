///|
/// Versioned, bounded logical-plan output. Physical execution choices belong
/// to the execution report, since the executor can fuse or specialize nodes.
pub(all) struct ExplainedPlan {
  schema_version : Int
  kind : String
  truncated : Bool
  nodes : Array[ExplainedNode]
} derive(ToJson)

///|
pub(all) struct ExplainedNode {
  id : Int
  parent : Int
  depth : Int
  operator : String
  detail : String
} derive(ToJson)

///|
/// Does not execute expressions or access table rows. At most 256 nodes,
/// 64 levels and 4096 expression visits; truncation is visible in the result.
pub fn explain_plan(
  plan : Plan,
  table_name : (Int, Int) -> String,
) -> ExplainedPlan {
  let builder : ExplainBuilder = {
    nodes: [],
    truncated: false,
    expressions: 0,
    table_name,
  }
  builder.visit(plan, -1, 0)
  {
    schema_version: 1,
    kind: "logical",
    truncated: builder.truncated,
    nodes: builder.nodes,
  }
}

///|
priv struct ExplainBuilder {
  nodes : Array[ExplainedNode]
  mut truncated : Bool
  mut expressions : Int
  table_name : (Int, Int) -> String
}

///|
fn ExplainBuilder::expression(
  self : ExplainBuilder,
  e : Expr,
  parent : Int,
  depth : Int,
) -> Unit {
  self.expressions += 1
  if self.expressions > 4096 || depth > 64 || self.nodes.length() >= 256 {
    self.truncated = true
    return
  }
  match e.kind {
    Subquery(p) | Exists(p) => self.visit(p, parent, depth)
    InQuery(a, p, ..) | Quantified(_, a, p, ..) => {
      self.expression(a, parent, depth + 1)
      self.visit(p, parent, depth)
    }
    Cast(a, ..) | Collate(a) | Neg(a) | BitNot(a) | Not(a) | IsNull(a, ..) =>
      self.expression(a, parent, depth + 1)
    Arith(_, a, b)
    | BitOp(_, a, b)
    | Cmp(_, a, b, _)
    | Concat(a, b)
    | And(a, b)
    | Or(a, b) => {
      self.expression(a, parent, depth + 1)
      self.expression(b, parent, depth + 1)
    }
    Like(a, b, escape~, ..) => {
      self.expression(a, parent, depth + 1)
      self.expression(b, parent, depth + 1)
      if escape is Some(e) {
        self.expression(e, parent, depth + 1)
      }
    }
    InList(a, xs, ..) => {
      self.expression(a, parent, depth + 1)
      for x in xs {
        self.expression(x, parent, depth + 1)
      }
    }
    Case(arms, fallback) => {
      for (a, b) in arms {
        self.expression(a, parent, depth + 1)
        self.expression(b, parent, depth + 1)
      }
      if fallback is Some(e) {
        self.expression(e, parent, depth + 1)
      }
    }
    Call(_, args) | UserFn(_, args) =>
      for e in args {
        self.expression(e, parent, depth + 1)
      }
    Lit(_) | Var(_) | Col(_) | OuterCol(_, _) | Global(_) => ()
  }
}

///|
fn ExplainBuilder::visit(
  self : ExplainBuilder,
  p : Plan,
  parent : Int,
  depth : Int,
) -> Unit {
  if self.nodes.length() >= 256 || depth > 64 {
    self.truncated = true
    return
  }
  let id = self.nodes.length()
  let (operator, detail, children, exprs) : (
    String,
    String,
    Array[Plan],
    Array[Expr],
  ) = match p {
    OneRow => ("OneRow", "", [], [])
    Scan(scope~, id~, ..) => ("Scan", (self.table_name)(scope, id), [], [])
    Values(rows) => ("Values", "rows=\{rows.length()}", [], rows.flatten())
    Join(kind, a, b, on, ..) => {
      let name = match kind {
        Inner => "Inner"
        Left => "Left"
        Right => "Right"
        Full => "Full"
        Cross => "Cross"
      }
      ("Join", name, [a, b], explain_optional(on))
    }
    Project(p, es) => ("Project", "expressions=\{es.length()}", [p], es)
    Filter(p, e) => ("Filter", "", [p], [e])
    Sort(p, keys) =>
      ("Sort", "keys=\{keys.length()}", [p], keys.map(k => k.expr))
    Limit(p, offset, count) =>
      ("Limit", "", [p], explain_optional(offset) + explain_optional(count))
    Distinct(p, _) => ("Distinct", "", [p], [])
    UnionAll(ps) => ("UnionAll", "", ps, [])
    Aggregate(p, keys, aggs, ..) =>
      (
        "Aggregate",
        "keys=\{keys.length()}, aggregates=\{aggs.length()}",
        [p],
        keys + aggs.filter_map(a => a.arg),
      )
    Window(p, calls) =>
      (
        "Window",
        "functions=\{calls.length()}",
        [p],
        calls
        .map(c => c.args + c.partition + c.order.map(k => k.expr))
        .flatten(),
      )
    Apply(a, b, outer~, ..) =>
      ("Apply", if outer { "Outer" } else { "Cross" }, [a, b], [])
    SetOp(kind, a, b, _) => {
      let name = match kind {
        Union => "Union"
        Except => "Except"
        Intersect => "Intersect"
      }
      (name, "", [a, b], [])
    }
    Top(p, e, percent~, ..) =>
      ("Top", if percent { "percent" } else { "rows" }, [p], [e])
    Recursive(id~, a, b, max~) =>
      ("Recursive", "work_table=\{id}, max_recursion=\{max}", [a, b], [])
    WorkTable(id) => ("WorkTable", "id=\{id}", [], [])
    TableFunc(_, args) => ("TableFunction", "", [], args)
    WithParams(args, p) => ("Parameters", "", [p], args)
    UserTable(id, args) =>
      ("UserTableFunction", "object_id=\{id}; body not expanded", [], args)
    ForJson(p, _, ..) => ("ForJson", "", [p], [])
    ForXml(p, _, _, ..) => ("ForXml", "", [p], [])
    NoNullWarning(p) => ("NoNullWarning", "", [p], [])
    Unpivot(p, ..) => ("Unpivot", "", [p], [])
    Concat(p) => ("Concat", "", [p], [])
  }
  self.nodes.push({ id, parent, depth, operator, detail, })
  for child in children {
    if self.nodes.length() >= 256 {
      self.truncated = true
      break
    }
    self.visit(child, id, depth + 1)
  }
  for e in exprs {
    if self.expressions >= 4096 || self.nodes.length() >= 256 {
      self.truncated = true
      break
    }
    self.expression(e, id, depth + 1)
  }
}

///|
pub fn ExplainedPlan::text(self : ExplainedPlan) -> String {
  let lines = self.nodes.map(n => {
    "  ".repeat(
      if n.depth < 0 {
        0
      } else if n.depth > 64 {
        64
      } else {
        n.depth
      },
    ) +
    n.operator +
    (if n.detail == "" { "" } else { " (" + n.detail + ")" })
  })
  if self.truncated {
    lines.push("[plan truncated]")
  }
  lines.join("\n")
}

///|
fn explain_optional(e : Expr?) -> Array[Expr] {
  match e {
    Some(e) => [e]
    None => []
  }
}
