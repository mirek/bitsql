///|
/// The isolation class of a table's locking hints for READPAST: "RU"
/// (NOLOCK, READUNCOMMITTED), "RC" (READCOMMITTED, READCOMMITTEDLOCK), "RR"
/// (REPEATABLEREAD), "SR" (SERIALIZABLE, HOLDLOCK), "" without one.
pub fn readpast_hint_class(hints : Array[@ast.TableHint]) -> String {
  for h in hints {
    match h.name {
      "NOLOCK" | "READUNCOMMITTED" => return "RU"
      "READCOMMITTED" | "READCOMMITTEDLOCK" => return "RC"
      "REPEATABLEREAD" => return "RR"
      "SERIALIZABLE" | "HOLDLOCK" => return "SR"
      _ => ()
    }
  }
  ""
}

///|
/// A FROM table (or view) read with READPAST: the scan runs behind a check
/// that the session evaluates when the scan opens (`%READPAST`, session
/// catalog_fn), because 650 depends on the session isolation level and is
/// raised at run time, after COLMETADATA, only when the table is read
/// (captured: tail5/b2-readpast; `WHERE 1=0` reads nothing).
fn readpast_guard(
  hints : Array[@ast.TableHint],
  plan : @ir.Plan,
  width : Int,
  view~ : Bool,
) -> @ir.Plan {
  if !hints.iter().any(h => h.name == "READPAST") {
    return plan
  }
  let check = mk(
    Call(Named("%READPAST"), [
      mk(
        Lit(String(readpast_hint_class(hints))),
        VarChar(Some(2), @types.default_collation),
        false,
      ),
      mk(Lit(Bit(view)), Bit, false),
    ]),
    Bit,
    false,
  )
  Join(
    Cross,
    Filter(OneRow, check),
    plan,
    None,
    left_width=0,
    right_width=width,
  )
}
