///|
/// SET statements. Options bitsql implements take effect; options whose
/// non-default value would change semantics bitsql does not model raise an
/// Emulator error instead of being ignored. Returns the statement's CurCmd,
/// or None when SQL Server sends no DONE for it (captured one statement per
/// batch: corpus set/each).
fn Session::set_options(
  self : Session,
  names : Array[String],
  value : @ast.SetValue,
  line : Int,
) -> Int? raise {
  let on = value is On
  let flag = if value is Off { 186 } else { 185 }
  let mut cmd : Int? = Some(flag)
  let unsupported = (n : String) => {
    @types.not_supported("SET \{n} \{set_value_text(value)}")
  }
  let number = () => {
    match value {
      ValueExpr(e) => {
        let (v, ty) = self.eval(e)
        match @types.cast(v, ty, Int) {
          Int(n) => Some(n)
          _ => None
        }
      }
      Word(w) => Some(@string.parse_int(w)) catch { _ => None }
      _ => None
    }
  }
  for n in names {
    match n.to_upper() {
      "NOCOUNT" => {
        self.nocount = on
        self.rt.option_bits = if on {
          self.rt.option_bits | 512
        } else {
          self.rt.option_bits & (512 ^ -1)
        }
      }
      "XACT_ABORT" => {
        self.xact_abort = on
        self.rt.option_bits = if on {
          self.rt.option_bits | 16384
        } else {
          self.rt.option_bits & (16384 ^ -1)
        }
      }
      // parse-time option: applied while the batch is parsed (run_text,
      // Session::quoted_identifier_scan), no DONE of its own
      "QUOTED_IDENTIFIER" => cmd = None
      // defaults bitsql implements; the other value changes semantics
      // OFF drops the 8153 warning; the run-time errors it would turn into
      // silent truncation or NULL are Emulator errors (interp.mbt)
      "ANSI_WARNINGS" => {
        self.session_flags["ANSI_WARNINGS"] = on
        self.rt.option_bits = if on {
          self.rt.option_bits & (8 ^ -1)
        } else {
          self.rt.option_bits | 8
        }
      }
      // inside a procedure, function or trigger the module's setting holds
      // and the statement sends no DONE (probed: tail/settings-ansi-nulls)
      "ANSI_NULLS" =>
        if self.frame().module_settings {
          cmd = None
        } else {
          self.set_ansi_nulls(on)
        }
      // OFF changes how new char/varchar/binary/varbinary columns store
      // trailing blanks and zeros: creating one is an Emulator error
      // (Session::check_ansi_padding)
      "ANSI_PADDING" => self.set_option_flag("ANSI_PADDING", on, 16, true)
      // OFF: `'a' + NULL` is 'a'; string `+` is an Emulator error then
      // (bind/set_options.mbt)
      "CONCAT_NULL_YIELDS_NULL" =>
        self.set_option_flag("CONCAT_NULL_YIELDS_NULL", on, 4096, true)
      // ON: precision loss is 8115 state 7; decimal, money and float
      // expressions are Emulator errors then (bind/set_options.mbt)
      "NUMERIC_ROUNDABORT" =>
        self.set_option_flag("NUMERIC_ROUNDABORT", on, 8192, false)
      "ANSI_NULL_DFLT_ON" => if !on { raise unsupported(n) }
      "ANSI_DEFAULTS" => if !on { raise unsupported(n) }
      "IMPLICIT_TRANSACTIONS"
      | "CURSOR_CLOSE_ON_COMMIT"
      | "NOEXEC"
      | "FMTONLY"
      | "PARSEONLY"
      | "ANSI_NULL_DFLT_OFF"
      | "FORCEPLAN"
      | "SHOWPLAN_ALL"
      | "SHOWPLAN_TEXT"
      | "SHOWPLAN_XML" => if on { raise unsupported(n) }
      // no effect while ANSI_WARNINGS is ON (@@OPTIONS bits 64 / 128)
      "ARITHABORT" => self.set_option_flag("ARITHABORT", on, 64, true)
      "ARITHIGNORE" => self.set_option_flag("ARITHIGNORE", on, 128, false)
      "STATISTICS"
      | "STATISTICS IO"
      | "STATISTICS TIME"
      | "STATISTICS XML"
      | "STATISTICS PROFILE" => {
        if on {
          raise unsupported(n)
        }
        cmd = Some(188)
      }
      "ROWCOUNT" => {
        if number() != Some(0) {
          raise unsupported(n)
        }
        cmd = Some(189)
      }
      "TEXTSIZE" => {
        match number() {
          Some(2147483647) | Some(-1) => ()
          _ => raise unsupported(n)
        }
        cmd = Some(190)
      }
      "DATEFIRST" => {
        self.cur_cmd = 249
        match number() {
          Some(d) if d >= 1 && d <= 7 => {
            self.rt.datefirst = d
            self.datefirst_set = true
          }
          // captured: msduck rpc-session-scope, statement-level
          Some(d) =>
            raise @types.sql_error(2742, "SET DATEFIRST \{d} is out of range.")
          // a NULL variable is 0 (captured: msduck rpc-session-scope #022)
          None if value is ValueExpr(e) && self.eval(e).0 is Null =>
            raise @types.sql_error(2742, "SET DATEFIRST 0 is out of range.")
          _ => raise unsupported(n)
        }
        cmd = Some(249)
      }
      // statement errors 2741 / 2740 complete with CurCmd 249 and the
      // batch goes on (captured: settings/dateformat, settings/language)
      "DATEFORMAT" => {
        self.cur_cmd = 249
        let text = self.set_text(value)
        match @types.DateFormat::parse(text) {
          Some(f) => {
            self.rt.dates = { ..self.rt.dates, format: f, }
            self.dateformat_set = true
          }
          None =>
            raise @types.sql_error(
              2741,
              "SET DATEFORMAT date order '\{text}' is invalid.",
            )
        }
        cmd = Some(249)
      }
      "LANGUAGE" => {
        self.cur_cmd = 249
        let text = self.set_text(value)
        guard @types.find_language(text) is Some(lang) else {
          raise @types.sql_error(
            2740,
            "SET LANGUAGE failed because '\{text}' is not an official language name or a language alias on this SQL Server.",
          )
        }
        let old = @types.language(self.rt.dates.language).name
        // the language's date order and first weekday, unless SET
        // DATEFORMAT / DATEFIRST ran earlier in this request
        self.rt.dates = {
          format: if self.dateformat_set {
            self.rt.dates.format
          } else {
            lang.dateformat
          },
          language: lang.langid,
        }
        if !self.datefirst_set {
          self.rt.datefirst = lang.datefirst
        }
        // captured: ENVCHANGE language, INFO 5703 in the new language, DONE
        // 249; inside EXEC / a procedure neither is sent (the setting
        // reverts when the module ends)
        if self.rt.nest_level == 0 {
          self.out.push(EnvChange(Language(lang.name, old)))
          self.info(5703, 1, lang.changed_message, line)
        }
        cmd = Some(249)
      }
      "DEADLOCK_PRIORITY" => {
        let p = match value {
          Word(w) =>
            match w.to_upper() {
              "LOW" => Some(-5)
              "NORMAL" => Some(0)
              "HIGH" => Some(5)
              _ => Some(@string.parse_int(w)) catch { _ => None }
            }
          _ => number()
        }
        match p {
          Some(p) if p >= -10 && p <= 10 =>
            self.server.set_priority(self.rt.spid, p)
          _ => raise unsupported(n)
        }
        cmd = Some(249)
      }
      "CONTEXT_INFO" => {
        match value {
          ValueExpr(e) => {
            let (v, ty) = self.eval(e)
            let bytes = match @types.cast(v, ty, VarBinary(Some(128))) {
              Binary(b) => b
              _ => b""
            }
            // padded with zeros to 128 bytes (captured: misc/context-info)
            self.context_info = Some(
              Bytes::makei(128, i => {
                if i < bytes.length() {
                  bytes[i]
                } else {
                  b'\x00'
                }
              }),
            )
          }
          _ => ()
        }
        cmd = Some(249)
      }
      "LOCK_TIMEOUT" => {
        match number() {
          Some(t) => {
            self.lock_timeout = t
            self.rt.lock_timeout = t
          }
          None => raise unsupported(n)
        }
        cmd = Some(249)
      }
      _ => raise unsupported(n)
    }
  }
  cmd
}

///|
fn set_value_text(v : @ast.SetValue) -> String {
  match v {
    On => "ON"
    Off => "OFF"
    Word(w) => w
    ValueExpr(_) => "<value>"
  }
}

///|
/// The text of a SET DATEFORMAT / SET LANGUAGE value as written: a bare or
/// bracketed word, a string or a variable ('' for NULL).
fn Session::set_text(self : Session, value : @ast.SetValue) -> String raise {
  match value {
    Word(w) => w
    On => "ON"
    Off => "OFF"
    ValueExpr(e) =>
      match self.eval(e) {
        (Null, _) => ""
        (v, ty) =>
          match @types.cast(v, ty, NVarChar(None, self.db_collation())) {
            String(s) => s
            _ => ""
          }
      }
  }
}

///|
/// Records a SET option for SESSIONPROPERTY and the binder, and its
/// @@OPTIONS bit (kept as a XOR mask over the login defaults).
fn Session::set_option_flag(
  self : Session,
  key : String,
  on : Bool,
  bit : Int,
  default : Bool,
) -> Unit {
  self.session_flags[key] = on
  self.rt.option_bits = if on == default {
    self.rt.option_bits & (bit ^ -1)
  } else {
    self.rt.option_bits | bit
  }
}

///|
/// The SET options error 1934 requires (indexed views, filtered and
/// computed-column indexes, XML methods) that are not at their required
/// values, in SQL Server's message order (probed: 'ANSI_NULLS,
/// ANSI_PADDING').
fn Session::wrong_index_options(self : Session) -> Array[String] {
  let out = []
  for
    k in [
      "ANSI_NULLS", "ANSI_PADDING", "ANSI_WARNINGS", "ARITHABORT", "CONCAT_NULL_YIELDS_NULL",
      "QUOTED_IDENTIFIER",
    ] {
    if !self.session_flags.get(k).unwrap_or(true) {
      out.push(k)
    }
  }
  if self.session_flags.get("NUMERIC_ROUNDABORT").unwrap_or(false) {
    out.push("NUMERIC_ROUNDABORT")
  }
  out
}

///|
/// Binder view of the SET options it checks.
fn Session::bind_options(self : Session) -> @bind.BindOptions {
  {
    concat_null_yields_null: self.session_flags
    .get("CONCAT_NULL_YIELDS_NULL")
    .unwrap_or(true),
    numeric_roundabort: self.session_flags
    .get("NUMERIC_ROUNDABORT")
    .unwrap_or(false),
    wrong_for_indexes: self.wrong_index_options(),
  }
}

///|
/// SET ANSI_PADDING OFF: new char/varchar/binary/varbinary columns would
/// drop trailing blanks and zeros (and nullable char behaves like varchar;
/// probed: tail/settings-options). Not modelled: an Emulator error.
fn Session::check_ansi_padding(
  self : Session,
  ty : @types.SqlType,
) -> Unit raise @types.SqlError {
  if self.session_flags.get("ANSI_PADDING").unwrap_or(true) {
    return
  }
  if ty is (Char(_, _) | VarChar(_, _) | Binary(_) | VarBinary(_)) {
    raise @types.not_supported(
      "char, varchar, binary or varbinary columns created under SET ANSI_PADDING OFF",
    )
  }
}

///|
/// SET QUOTED_IDENTIFIER is a parse-time option: every SET in the batch
/// (also in branches that do not run) applies while the batch is parsed,
/// to the tokens after it, and the batch then runs with the last value
/// (probed: tail/settings-options, `SET QUOTED_IDENTIFIER OFF; SELECT
/// SESSIONPROPERTY(...); SET QUOTED_IDENTIFIER ON` reads 1). OFF reads "x"
/// as a string literal; bitsql parses it as an identifier, so a
/// double-quoted token where the option is OFF is an Emulator error.
/// Applies the final value and returns that token's line.
fn Session::quoted_identifier_scan(self : Session, text : String) -> Int? {
  let mut on = self.session_flags.get("QUOTED_IDENTIFIER").unwrap_or(true)
  if on && !contains_ascii_ci(text, "quoted_identifier") {
    return None
  }
  let toks = @lex.lex(text) catch { _ => return None }
  let mut conflict : Int? = None
  for k, t in toks {
    if t.is_kw("QUOTED_IDENTIFIER") &&
      k > 0 &&
      toks[k - 1].is_kw("SET") &&
      k + 1 < toks.length() {
      if toks[k + 1].is_kw("ON") {
        on = true
        self.set_option_flag("QUOTED_IDENTIFIER", true, 256, true)
      } else if toks[k + 1].is_kw("OFF") {
        on = false
        self.set_option_flag("QUOTED_IDENTIFIER", false, 256, true)
      }
    }
    if conflict is None &&
      !on &&
      t.kind is QuotedIdent &&
      t.span.start < text.length() &&
      text[t.span.start] == '"' {
      conflict = Some(t.span.line)
    }
  }
  conflict
}

///|
/// ASCII case-insensitive substring test (`word` lower case).
fn contains_ascii_ci(text : String, word : String) -> Bool {
  let n = word.length()
  if n == 0 {
    return true
  }
  for i = 0; i + n <= text.length(); i = i + 1 {
    let mut ok = true
    for j in 0..<n {
      let c = text[i + j].to_int()
      let c = if c >= 65 && c <= 90 { c + 32 } else { c }
      if c != word[j].to_int() {
        ok = false
        break
      }
    }
    if ok {
      return true
    }
  }
  false
}

///|
/// DML on a table with a filtered index or an index on a computed column
/// needs the index SET options; otherwise SQL Server raises 1934 and ends
/// the batch (probed: tail/settings-options, "INSERT failed because the
/// following SET options have incorrect settings: 'ANSI_NULLS'."). Not
/// modelled: an Emulator error.
fn Session::check_index_options(
  self : Session,
  t : @store.Table,
) -> Unit raise @types.SqlError {
  if self.session_flags.is_empty() {
    return
  }
  // plain loops: this runs for every row a statement writes
  let mut special = false
  for ix in t.indexes {
    if ix.filter is Some(_) {
      special = true
      break
    }
    for c in ix.columns {
      if t.columns[c.0].computed is Some(_) {
        special = true
      }
    }
    for c in ix.included {
      if t.columns[c].computed is Some(_) {
        special = true
      }
    }
  }
  if !special {
    return
  }
  let wrong = self.wrong_index_options()
  if !wrong.is_empty() {
    raise @types.not_supported(
      "changing a table with a filtered or computed-column index under SET " +
      wrong.join(", ") +
      " (SQL Server error 1934)",
    )
  }
}
