// The deprecated large-object types text, ntext and image.
//
// Captured on SQL Server 2025 (harness/corpus/conversion/lob-*.cases.json):
//
// - CAST/CONVERT: text and ntext convert to and from char, varchar, nchar,
//   nvarchar (also max) and each other; image converts to and from binary,
//   varbinary and timestamp, and from char/varchar (not nchar/nvarchar),
//   but to no character type. Everything else is 529. Implicit conversions
//   follow the same table.
// - Precedence: ntext > text > image, just above timestamp (CASE text/'x'
//   is text).
// - Comparisons (=, <>, <, IN, NULLIF, joins), `+` and arithmetic: 402
//   "The data types text and varchar are incompatible in the equal to
//   operator."; ORDER BY / GROUP BY 306 state 2; DISTINCT 421; UNION 5335;
//   MIN/MAX/COUNT 8117; local variables 2739. LIKE and IS NULL work (LIKE on
//   image: 8116 for argument 2).
// - Wire: TEXT 0x23, NTEXT 0x63, IMAGE 0x22 with lengths 2147483647,
//   2147483646 and 2147483647 (tds/type_info.mbt).

///|
/// text, ntext or image.
pub fn SqlType::is_lob(self : SqlType) -> Bool {
  self is (Text(_) | NText(_) | Image)
}

///|
/// The conversion table of the LOB types (both implicit and explicit).
fn lob_convertible(from : SqlType, to : SqlType) -> Bool {
  let character = (t : SqlType) => {
    t
    is (Char(_, _)
    | VarChar(_, _)
    | NChar(_, _)
    | NVarChar(_, _)
    | Text(_)
    | NText(_))
  }
  match (from, to) {
    // captured: CAST(text AS xml) works, xml → text is 529
    (Text(_) | NText(_), t) => character(t) || t is Xml
    (f, Text(_) | NText(_)) => character(f)
    (Image, t) => t is (Binary(_) | VarBinary(_) | RowVersion | Image)
    (f, Image) =>
      f
      is (Binary(_)
      | VarBinary(_)
      | RowVersion
      | Image
      | Char(_, _)
      | VarChar(_, _))
    _ => false
  }
}

///|
/// 402: a LOB operand of a comparison or arithmetic operator (`op` is the
/// operator's message name: "equal to", "add", "greater than", …).
pub fn lob_operator_error(a : SqlType, b : SqlType, op : String) -> SqlError {
  sql_error(
    402,
    "The data types \{a.base_name()} and \{b.base_name()} are incompatible in the \{op} operator.",
  )
}

///|
/// 306 state 2: a LOB ORDER BY or GROUP BY key.
pub fn lob_sort_error() -> SqlError {
  sql_error(
    306,
    "The text, ntext, and image data types cannot be compared or sorted, except when using IS NULL or LIKE operator.",
    state=2,
  )
}

///|
/// 421: a LOB column under SELECT DISTINCT.
pub fn lob_distinct_error(t : SqlType) -> SqlError {
  sql_error(
    421,
    "The \{t.base_name()} data type cannot be selected as DISTINCT because it is not comparable.",
  )
}

///|
/// 5335: a LOB column in UNION, INTERSECT or EXCEPT (UNION ALL works).
pub fn lob_union_error(t : SqlType) -> SqlError {
  sql_error(
    5335,
    "The data type \{t.base_name()} cannot be used as an operand to the UNION, INTERSECT or EXCEPT operators because it is not comparable.",
  )
}

///|
/// 2739: DECLARE @v text.
pub fn lob_variable_error() -> SqlError {
  sql_error(
    2739, "The text, ntext, and image data types are invalid for local variables.",
  )
}
