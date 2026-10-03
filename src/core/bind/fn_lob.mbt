// Built-in functions over text, ntext and image arguments (captured:
// harness/corpus/conversion/lob-functions.cases.json).
//
// Most string functions reject them with 8116 ("Argument data type text is
// invalid for argument 1 of len function."; state 4 for CHECKSUM, GREATEST
// and LEAST); DATALENGTH, SUBSTRING, CHARINDEX, PATINDEX, CONCAT,
// CONCAT_WS, ISNULL, COALESCE, IIF, QUOTENAME and DIFFERENCE (text only)
// accept text/ntext. image is accepted by DATALENGTH, SUBSTRING, ISNULL,
// COALESCE and IIF; CHARINDEX, CONCAT, CONCAT_WS and QUOTENAME report the
// image → character conversion as 206, PATINDEX as 8116.

///|
/// Function name as 8116 prints it, and the error state.
fn lob_rejecting(name : String) -> (String, Int)? {
  match name {
    "LEN"
    | "LEFT"
    | "RIGHT"
    | "UPPER"
    | "LOWER"
    | "LTRIM"
    | "RTRIM"
    | "REPLACE"
    | "REVERSE"
    | "STUFF"
    | "REPLICATE"
    | "ASCII"
    | "UNICODE"
    | "SOUNDEX"
    | "STRING_ESCAPE"
    | "FORMAT"
    | "TRANSLATE"
    | "ISJSON"
    | "JSON_VALUE"
    | "JSON_QUERY"
    | "HASHBYTES"
    | "STRING_AGG" => Some((name.to_lower(), 1))
    "TRIM" => Some(("Trim", 1))
    "COMPRESS" => Some(("Compress", 1))
    "CHECKSUM" | "GREATEST" | "LEAST" => Some((name.to_lower(), 4))
    _ => None
  }
}

///|
fn lob_accepting(name : String) -> Bool {
  name
  is ("DATALENGTH"
  | "SUBSTRING"
  | "CHARINDEX"
  | "PATINDEX"
  | "CONCAT"
  | "CONCAT_WS"
  | "ISNULL"
  | "COALESCE"
  | "IIF"
  | "NULLIF"
  | "QUOTENAME"
  | "DIFFERENCE"
  | "BINARY_CHECKSUM")
}

///|
/// CONCAT / CONCAT_WS: the arguments convert to nvarchar when one of them
/// (the separator included) is a Unicode character type, else to varchar;
/// xml and sql_variant do not make it Unicode. The first argument in
/// order that cannot convert raises: xml / sql_variant 257, image 206
/// (captured: msduck concat-legacy-family, e.g. CONCAT_WS('', xml, text)
/// is "xml to varchar", CONCAT_WS('', image, xml) is the image 206).
fn concat_guard(
  env : Env,
  name : String,
  args : Array[@ast.Expr],
) -> Unit raise @types.SqlError {
  if !(name is ("CONCAT" | "CONCAT_WS")) {
    return
  }
  let tys : Array[@types.SqlType] = []
  for a in args {
    let t = bind_expr(env, a).ty catch { _ => return }
    tys.push(t)
  }
  if !tys.iter().any(t => t is (Xml | Variant | Image)) {
    return
  }
  let target : @types.SqlType = if tys.iter().any(t => t.is_unicode()) {
    NVarChar(Some(1), @types.default_collation)
  } else {
    VarChar(Some(1), @types.default_collation)
  }
  for t in tys {
    match t {
      Xml | Variant => raise @types.implicit_conversion_error(t, target)
      Image => raise @types.type_clash_error(Image, target)
      _ => ()
    }
  }
}

///|
/// Raises SQL Server's error for a text/ntext/image argument the function
/// does not take. Arguments are bound only for the functions listed above
/// (others may take identifiers, e.g. DATEADD's datepart).
fn lob_guard(
  env : Env,
  name : String,
  args : Array[@ast.Expr],
) -> Unit raise @types.SqlError {
  let rejecting = lob_rejecting(name)
  if rejecting is None && !lob_accepting(name) {
    return
  }
  let tys : Array[@types.SqlType] = []
  for a in args {
    let t = bind_expr(env, a).ty catch { _ => return }
    tys.push(t)
  }
  for i, t in tys {
    if !t.is_lob() {
      continue
    }
    let invalid = (label : String, state : Int) => {
      err(
        8116,
        "Argument data type \{t.base_name()} is invalid for argument \{i + 1} of \{label} function.",
        state~,
      )
    }
    match rejecting {
      Some((label, state)) => raise invalid(label, state)
      None => ()
    }
    match (name, t) {
      ("BINARY_CHECKSUM", _) =>
        if tys.iter().all(u => u.is_lob()) {
          raise err(
            8184, "Error in binarychecksum. There are no comparable columns in the binarychecksum input.",
          )
        } else {
          raise @types.not_supported(
            "BINARY_CHECKSUM over text, ntext or image with other columns",
          )
        }
      ("DIFFERENCE", NText(_) | Image) => raise invalid("difference", 1)
      ("PATINDEX", Image) => raise invalid("patindex", 1)
      ("CHARINDEX" | "CONCAT" | "CONCAT_WS", Image) => {
        let unicode = tys.iter().any(u => u.is_unicode())
        raise @types.type_clash_error(
          Image,
          if unicode {
            NVarChar(Some(1), @types.default_collation)
          } else {
            VarChar(Some(1), @types.default_collation)
          },
        )
      }
      ("QUOTENAME", Image) =>
        raise @types.type_clash_error(
          Image,
          NVarChar(Some(1), @types.default_collation),
        )
      _ => ()
    }
  }
}
