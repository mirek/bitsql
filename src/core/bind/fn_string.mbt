// String built-ins. Result lengths fold constant arguments the way SQL
// Server does (captured: LEFT('abcdef', 3) is varchar(3), REPLICATE('x', 1+2)
// varchar(3), SPACE(NULL) varchar(8000)); nearly every result is nullable
// (flags 33) even for literal arguments. Evaluated in exec/fn_string.mbt.
// Captures: harness/corpus/functions/string.cases.json and msduck
// left-right*, replicate*, space-*, trim-collation, character-*.

///|
fn with_collation(t : @types.SqlType, c : @types.Collation) -> @types.SqlType {
  match t {
    VarChar(n, _) => VarChar(n, c)
    NVarChar(n, _) => NVarChar(n, c)
    Char(n, _) => Char(n, c)
    NChar(n, _) => NChar(n, c)
    other => other
  }
}

///|
fn bind_string_fn(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  let args = call.args
  let b = (i : Int) => bind_expr(env, args[i])
  let r = match name {
    "LEN" | "DATALENGTH" => {
      arity_n(name, args, 1)
      let x = b(0)
      let ty : @types.SqlType = if is_max_string(x.ty) { BigInt } else { Int }
      if name == "LEN" {
        named("LEN", [as_string_arg(x, env)], ty)
      } else {
        named("DATALENGTH", [x], ty)
      }
    }
    "UPPER" | "LOWER" | "REVERSE" => {
      arity_n(name, args, 1)
      let x = b(0)
      let ty = string_arg_type(x, env)
      // UTF-8 varchar: case mapping may grow the bytes, so UPPER/LOWER are
      // varchar(8 * n) up to 8000, also of char (captured: settings/utf8)
      let ty = match ty {
        VarChar(Some(n), c) | Char(n, c) if c.utf8() && name != "REVERSE" =>
          @types.SqlType::VarChar(Some(@cmp.minimum(8 * n, 8000)), c)
        t => t
      }
      named(name, [as_string_arg(x, env)], ty)
    }
    "LTRIM" | "RTRIM" | "TRIM" | "TRIM LEADING" | "TRIM TRAILING" => {
      let fname = if name.has_prefix("TRIM") { "TRIM" } else { name }
      if fname == "TRIM" {
        arity_n(fname, args, if args.length() == 2 { 2 } else { 1 })
      } else {
        arity_189(fname, args, 1, 2)
      }
      let x = b(0)
      let mut ty = string_arg_type(x, env)
      let bs = [as_string_arg(x, env)]
      if args.length() == 2 {
        // TRIM(chars FROM s) arrives as (s, chars); SQL Server resolves the
        // TRIM syntax as (chars, s) and LTRIM/RTRIM as (s, chars)
        // (captured 468 texts name the later operand first).
        let chars = b(1)
        let ops = if fname == "TRIM" { [chars, x] } else { [x, chars] }
        let op = if fname == "TRIM" { "Trim" } else { fname.to_lower() }
        match resolve_collation(env, op, ops) {
          Some(c) => ty = with_collation(ty, c)
          None => ()
        }
        bs.push(as_string_arg(chars, env))
      }
      let op = match name {
        "TRIM LEADING" => "LTRIM"
        "TRIM TRAILING" => "RTRIM"
        other => other
      }
      named(op, bs, ty)
    }
    "LEFT" | "RIGHT" => {
      arity_n(name, args, 2)
      let x = b(0)
      let n = b(1)
      let base = string_arg_type(x, env)
      let len = match (arg_len(x), fold_int(n)) {
        (None, _) => None
        // UTF-8 varchar: k characters take up to 8k bytes (captured:
        // settings/utf8, LEFT(varchar(10) …_UTF8, 1) is varchar(8), of 2
        // varchar(10), LEFT(varchar(100), 3) varchar(24))
        (Some(l), Some(k)) if utf8_text_type(base) && k >= 0L =>
          Some(
            @cmp.maximum(
              1,
              @cmp.minimum(@cmp.minimum(k, l.to_int64()) * 8L, l.to_int64()).to_int(),
            ),
          )
        (Some(l), Some(k)) => {
          if k < 0L {
            raise err(
              536,
              "Invalid length parameter passed to the \{name.to_lower()} function.",
              state=6,
            )
          }
          Some(@cmp.maximum(1, @cmp.minimum(k, l.to_int64()).to_int()))
        }
        (Some(l), None) => Some(l)
      }
      named(name, [as_string_arg(x, env), as_int_arg(n)], sized_like(base, len))
    }
    "SUBSTRING" => {
      arity_n(name, args, 3)
      let x = b(0)
      if is_null_lit(x) {
        raise null_arg(1, "substring")
      }
      if !(x.ty.family() is (FString | FBinary)) {
        raise bad_arg_type(x.ty, 1, "substring")
      }
      let start = b(1)
      let n = b(2)
      let k = fold_int(n)
      if k is Some(v) && v < 0L {
        raise err(
          536,
          "Invalid length parameter passed to the substring function.",
          state=8,
        )
      }
      let base = match x.ty {
        Binary(l) => @types.SqlType::VarBinary(Some(l))
        VarBinary(l) => @types.SqlType::VarBinary(l)
        Image => @types.SqlType::VarBinary(None)
        _ => string_arg_type(x, env)
      }
      let ty : @types.SqlType = match (base, k) {
        // captured: SUBSTRING(text, 2, 1) is varchar(1), of ntext
        // nvarchar(1), of image varbinary(1)
        (VarBinary(_), Some(v)) if x.ty.is_lob() =>
          VarBinary(Some(@cmp.maximum(1L, v).to_int()))
        (t, Some(v)) if x.ty.is_lob() =>
          sized_like(t, Some(@cmp.maximum(1L, v).to_int()))
        (VarBinary(Some(l)), Some(v)) =>
          VarBinary(
            Some(@cmp.maximum(1, @cmp.minimum(v, l.to_int64()).to_int())),
          )
        (VarBinary(l), _) => VarBinary(l)
        (t, Some(v)) if utf8_text_type(t) =>
          match string_len(t) {
            Some(l) =>
              sized_like(
                t,
                Some(
                  @cmp.maximum(
                    1,
                    @cmp.minimum(
                      @cmp.minimum(v, l.to_int64()) * 8L,
                      l.to_int64(),
                    ).to_int(),
                  ),
                ),
              )
            None => t
          }
        (t, Some(v)) =>
          match string_len(t) {
            Some(l) =>
              sized_like(
                t,
                Some(@cmp.maximum(1, @cmp.minimum(v, l.to_int64()).to_int())),
              )
            None => t
          }
        (t, None) => t
      }
      named("SUBSTRING", [x, as_int_arg(start), as_int_arg(n)], ty)
    }
    "REPLACE" => {
      arity_n(name, args, 3)
      let bs = [b(0), b(1), b(2)]
      let s = string_arg_type(bs[0], env)
      let unicode = bs.iter().any(x => x.ty.is_unicode())
      let ty : @types.SqlType = if is_max_string(s) {
        sized_like(if unicode { nvarchar(None) } else { s }, None)
      } else if unicode {
        NVarChar(Some(4000), s.collation().unwrap_or(env.collation))
      } else {
        VarChar(Some(8000), s.collation().unwrap_or(env.collation))
      }
      let (bs, coll) = collate_args(env, "replace", bs)
      let ty = match coll {
        Some(c) => with_collation(ty, c)
        None => ty
      }
      named("REPLACE", bs.map(x => as_string_arg(x, env)), ty)
    }
    "REPLICATE" => {
      arity_n(name, args, 2)
      let x = b(0)
      let n = b(1)
      let base = string_arg_type(x, env)
      let unicode = base.is_unicode()
      let cap = if unicode { 4000 } else { 8000 }
      let len = match (arg_len(x), fold_int(n)) {
        (None, _) => None
        (Some(l), Some(k)) =>
          if k <= 0L {
            // captured: a zero or negative count types the result as 2 bytes
            Some(if unicode { 1 } else { 2 })
          } else if l.to_int64() * k > cap.to_int64() {
            Some(cap)
          } else {
            Some(l * k.to_int())
          }
        (Some(_), None) => Some(cap)
      }
      named(
        "REPLICATE",
        [as_string_arg(x, env), as_int_arg(n)],
        sized_like(base, len),
      )
    }
    "SPACE" => {
      arity_n(name, args, 1)
      let n = b(0)
      let len = match fold_int(n) {
        Some(k) =>
          if k <= 0L {
            1
          } else if k > 8000L {
            8000
          } else {
            k.to_int()
          }
        None => 8000
      }
      named("SPACE", [as_int_arg(n)], VarChar(Some(len), env.collation))
    }
    "CHARINDEX" => {
      arity_189(name, args, 2, 3)
      let bs = args.map(a => bind_expr(env, a))
      let ty : @types.SqlType = if is_max_string(bs[1].ty) {
        BigInt
      } else {
        Int
      }
      let (two, _) = collate_args(env, "charindex", [bs[0], bs[1]])
      let conv = [as_string_arg(two[0], env), as_string_arg(two[1], env)]
      if bs.length() == 3 {
        // captured: a float or varchar start is 8116 (argument 3)
        if bs[2].ty.family() is (FString | FFloat) && !is_null_lit(bs[2]) {
          raise bad_arg_type(bs[2].ty, 3, "charindex")
        }
        conv.push(as_int_arg(bs[2]))
      }
      named("CHARINDEX", conv, ty)
    }
    "PATINDEX" => {
      arity_n(name, args, 2)
      let p = b(0)
      let s = b(1)
      if is_null_lit(s) {
        raise null_arg(2, "patindex")
      }
      if s.ty.family() != FString {
        raise bad_arg_type(s.ty, 2, "patindex")
      }
      if !is_null_lit(p) && p.ty.family() != FString {
        raise bad_arg_type(p.ty, 1, "patindex")
      }
      let ty : @types.SqlType = if is_max_string(s.ty) { BigInt } else { Int }
      let (ps, _) = collate_args(env, "patindex", [p, s])
      named("PATINDEX", ps, ty)
    }
    "CONCAT" => {
      if args.length() < 2 || args.length() > 254 {
        raise err(
          189,
          "The concat function requires 2 to 254 arguments.",
          severity=15,
        )
      }
      let bs = args.map(a => bind_expr(env, a))
      let ty = concat_type(env, bs, None)
      named("CONCAT", unicode_binary_args(bs, ty), ty, nullable=false)
    }
    "CONCAT_WS" => {
      if args.length() < 3 || args.length() > 254 {
        raise err(
          189,
          "The concat_ws function requires 3 to 254 arguments.",
          severity=15,
        )
      }
      let bs = args.map(a => bind_expr(env, a))
      let (bs, _) = collate_args(env, "concat_ws", bs)
      let values = bs[1:].to_owned()
      let ty = concat_type(env, values, Some(bs[0]))
      named("CONCAT_WS", unicode_binary_args(bs, ty), ty, nullable=false)
    }
    "NCHAR" => {
      arity_n(name, args, 1)
      named("NCHAR", [as_int_arg(b(0))], NChar(1, env.collation))
    }
    "CHAR" => {
      arity_n(name, args, 1)
      named("CHAR", [as_int_arg(b(0))], Char(1, env.collation))
    }
    "ASCII" | "UNICODE" => {
      arity_n(name, args, 1)
      named(name, [as_string_arg(b(0), env)], Int)
    }
    "STUFF" => {
      arity_n(name, args, 4)
      let (sr, _) = collate_args(env, "stuff", [b(0), b(3)])
      let s = sr[0]
      let start = b(1)
      let n = b(2)
      let rep = sr[1]
      require_numeric(start, 2, "stuff")
      require_numeric(n, 3, "stuff")
      let base = string_arg_type(s, env)
      let unicode = base.is_unicode() || rep.ty.is_unicode()
      let cap = if unicode { 4000 } else { 8000 }
      let c = base.collation().unwrap_or(env.collation)
      let ty : @types.SqlType = if is_null_lit(n) {
        // captured: STUFF('abc', 1, NULL, 'x') is nvarchar(4000)
        NVarChar(Some(4000), c)
      } else {
        let len = match (arg_len(s), arg_len(rep)) {
          (Some(l), Some(r)) => {
            let ks = if start.ty.family() == FInteger || is_null_lit(start) {
              fold_int(start)
            } else {
              None
            }
            let kn = fold_int(n)
            match (ks, kn) {
              (Some(st), Some(d)) =>
                if st > l.to_int64() {
                  Some(cap)
                } else {
                  let del = if st >= 1L {
                    @cmp.minimum(d, l.to_int64() - st + 1L)
                  } else {
                    d
                  }
                  Some(
                    @cmp.minimum(
                      cap.to_int64(),
                      l.to_int64() - del + r.to_int64(),
                    ).to_int(),
                  )
                }
              // captured: a variable or non-integer start/length gives the
              // full capacity (STUFF(@s, @i, @j, 'XY') is varchar(8000))
              _ => Some(cap)
            }
          }
          _ => None
        }
        if unicode {
          NVarChar(len, c)
        } else {
          VarChar(len, c)
        }
      }
      named(
        "STUFF",
        [
          as_string_arg(s, env),
          as_int_arg(start),
          as_int_arg(n),
          as_string_arg(rep, env),
        ],
        ty,
      )
    }
    "STR" => {
      arity_189(name, args, 1, 3)
      let bs = args.map(a => bind_expr(env, a))
      let len = if bs.length() < 2 {
        10
      } else {
        match fold_int(bs[1]) {
          Some(k) =>
            if k <= 0L {
              1
            } else if k > 8000L {
              8000
            } else {
              k.to_int()
            }
          None => 8000
        }
      }
      let conv = [if is_null_lit(bs[0]) { bs[0] } else { coerce(bs[0], Float) }]
      for i in 1..<bs.length() {
        conv.push(as_int_arg(bs[i]))
      }
      named("STR", conv, VarChar(Some(len), env.collation))
    }
    "QUOTENAME" => {
      arity_189(name, args, 1, 2)
      let bs = args.map(a => as_string_arg(bind_expr(env, a), env))
      named("QUOTENAME", bs, NVarChar(Some(258), env.collation))
    }
    "STRING_ESCAPE" => {
      arity_n(name, args, 2)
      let s = b(0)
      if !is_null_lit(s) && s.ty.family() != FString {
        raise bad_arg_type(s.ty, 1, "string_escape")
      }
      // a NULL literal kind is a compile error (lower-case name, state 1);
      // a typed NULL fails at run time (msduck string-escape-format)
      let k = b(1)
      if is_null_lit(k) {
        raise null_arg(2, "string_escape")
      }
      named("STRING_ESCAPE", [s, k], NVarChar(None, env.collation))
    }
    "TRANSLATE" => {
      arity_n(name, args, 3)
      let (bs, _) = collate_args(env, "translate", [b(0), b(1), b(2)])
      // captured: TRANSLATE('a1b', '1', 2) is 8116 for argument 3
      for i in 1..<3 {
        if !is_null_lit(bs[i]) && bs[i].ty.family() != FString {
          raise bad_arg_type(bs[i].ty, i + 1, "translate")
        }
      }
      let s = string_arg_type(bs[0], env)
      // captured: any Unicode argument makes the result nvarchar
      let to_unicode = !s.is_unicode() && bs.iter().any(x => x.ty.is_unicode())
      let s = if to_unicode {
        @types.SqlType::NVarChar(
          string_len(s),
          s.collation().unwrap_or(env.collation),
        )
      } else {
        s
      }
      // a binary source reads as UTF-16LE (captured: TRANSLATE(CAST(0x4142
      // AS binary(10)), N'A', N'Z') is N'䉁' + 4 NULs)
      let bs = if to_unicode {
        [unicode_binary_args([bs[0]], s)[0], bs[1], bs[2]]
      } else {
        bs
      }
      let ty = if is_max_string(s) { s } else { sized_like(s, Some(8000)) }
      // whether the mapping strings are only known at run time (a variable,
      // parameter or base-table column): their 9828 is state 3
      let runtime = [args[1], args[2]]
        .iter()
        .any(x => {
          any_expr(x, y => {
            match y.kind {
              Var(_) => true
              Column(_) =>
                is_base_column(bind_expr(env, y), env) catch {
                  _ => false
                }
              _ => false
            }
          })
        })
      named(
        "TRANSLATE",
        bs.map(x => as_string_arg(x, env)) + [mk(Lit(Bit(runtime)), Bit, false)],
        ty,
      )
    }
    "FORMAT" => {
      arity_189(name, args, 2, 3)
      let bs = args.map(a => bind_expr(env, a))
      if is_null_lit(bs[0]) {
        raise null_arg(1, "format")
      }
      if bs[0].ty.family() is (FString | FBinary | FGuid | FBit) {
        raise bad_arg_type(bs[0].ty, 1, "format")
      }
      if is_null_lit(bs[1]) {
        raise null_arg(2, "format")
      }
      named("FORMAT", bs, NVarChar(Some(4000), env.collation))
    }
    "SOUNDEX" => {
      arity_n(name, args, 1)
      // the result takes a varchar argument's collation (captured: 'x'
      // COLLATE Latin1_General_BIN2 gives a BIN2 result)
      let x = b(0)
      let coll = match x.ty {
        VarChar(_, c) | Char(_, c) => c
        _ => env.collation
      }
      // compatibility level 100 and below: H and W always separate
      // (captured: msduck soundex-difference #015)
      let fname = if (env.catalog.compat_level)() < 110 {
        "SOUNDEX_100"
      } else {
        "SOUNDEX"
      }
      named(fname, [as_string_arg(x, env)], VarChar(Some(5), coll))
    }
    "DIFFERENCE" => {
      arity_n(name, args, 2)
      named(
        if (env.catalog.compat_level)() < 110 {
          "DIFFERENCE_100"
        } else {
          "DIFFERENCE"
        },
        [as_string_arg(b(0), env), as_string_arg(b(1), env)],
        Int,
      )
    }
    _ => return None
  }
  // A string argument without a collation (a CASE or `+` over different
  // implicit collations) fails in every collation-aware string function
  // (captured probes: LEN/UPPER/LEFT(a+b) is 4191 "for len operation").
  // CONCAT only propagates it (451 later, msduck collation-functions #038).
  if !(name is ("CONCAT" | "CONCAT_WS")) && r.kind is Call(_, args) {
    let op = match name {
      "TRIM LEADING" | "TRIM TRAILING" => "trim"
      other => other.to_lower()
    }
    check_deferred_collation(env, op, args)
  }
  Some(r)
}

///|
/// With a Unicode CONCAT result, binary arguments convert to nvarchar by
/// reinterpreting their bytes as UTF-16LE (captured: CONCAT(0x414243,
/// N'') is N'䉁C'), not through the code page.
fn unicode_binary_args(
  bs : Array[@ir.Expr],
  ty : @types.SqlType,
) -> Array[@ir.Expr] {
  if !ty.is_unicode() {
    return bs
  }
  bs.map(x => {
    if x.ty.family() is FBinary && !is_null_lit(x) {
      let n = string_len(x.ty).map(n => @cmp.maximum(1, (n + 1) / 2))
      {
        kind: Cast(x, try_=false, style=None),
        ty: NVarChar(n, ty.collation().unwrap_or(@types.default_collation)),
        nullable: x.nullable,
      }
    } else {
      x
    }
  })
}

///|
/// CONCAT / CONCAT_WS result type: Unicode if any argument is; lengths add
/// up (a bare NULL counts 0, captured), separators once between values;
/// max beyond 8000 bytes; at least 1.
fn concat_type(
  env : Env,
  values : Array[@ir.Expr],
  sep : @ir.Expr?,
) -> @types.SqlType {
  let all = match sep {
    Some(s) => [s] + values
    None => values
  }
  let unicode = all.iter().any(x => x.ty.is_unicode())
  let mut total = 0
  let mut max = false
  let len0 = (x : @ir.Expr) => {
    if is_null_lit(x) {
      Some(0)
    } else if unicode && x.ty.family() is FBinary {
      // binary reads as UTF-16LE: ceil(bytes / 2) characters (captured:
      // CONCAT_WS(N'', binary(3), N'') is nvarchar(4))
      string_len(x.ty).map(n => (n + 1) / 2)
    } else {
      string_len(x.ty)
    }
  }
  for x in values {
    match len0(x) {
      Some(n) => total += n
      None => max = true
    }
  }
  match sep {
    Some(s) =>
      match len0(s) {
        Some(n) => total += n * (values.length() - 1)
        None => max = true
      }
    None => ()
  }
  let cap = if unicode { 4000 } else { 8000 }
  // capped, not max, without a max argument (captured: CONCAT_WS(N'',
  // nvarchar(3999), nvarchar(2)) is nvarchar(4000); msduck concat-boundary)
  let n = if max {
    None
  } else {
    Some(@cmp.minimum(@cmp.maximum(1, total), cap))
  }
  let coll = label_collation(env, all)
  if unicode {
    NVarChar(n, coll)
  } else {
    VarChar(n, coll)
  }
}

///|
/// A bound column reference to a base-table column of the current scope.
fn is_base_column(e : @ir.Expr, env : Env) -> Bool {
  match e.kind {
    Col(i) =>
      match env.columns.get(i) {
        Some(c) => c.origin is BaseColumn(..)
        None => false
      }
    _ => false
  }
}

///|
/// varchar/char under a UTF-8 collation (lengths are bytes, not characters).
fn utf8_text_type(t : @types.SqlType) -> Bool {
  match t {
    VarChar(_, c) | Char(_, c) => c.utf8()
    _ => false
  }
}
