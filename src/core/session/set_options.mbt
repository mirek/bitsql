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
      // compile-time option: no DONE of its own
      "QUOTED_IDENTIFIER" => {
        if !on {
          raise unsupported(n)
        }
        cmd = None
      }
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
      "ANSI_NULLS"
      | "ANSI_PADDING"
      | "ANSI_NULL_DFLT_ON"
      | "CONCAT_NULL_YIELDS_NULL" => if !on { raise unsupported(n) }
      "ANSI_DEFAULTS" => if !on { raise unsupported(n) }
      "NUMERIC_ROUNDABORT"
      | "IMPLICIT_TRANSACTIONS"
      | "CURSOR_CLOSE_ON_COMMIT"
      | "NOEXEC"
      | "FMTONLY"
      | "PARSEONLY"
      | "ANSI_NULL_DFLT_OFF"
      | "FORCEPLAN"
      | "SHOWPLAN_ALL"
      | "SHOWPLAN_TEXT"
      | "SHOWPLAN_XML" => if on { raise unsupported(n) }
      // no effect while ANSI_WARNINGS is ON
      "ARITHABORT" | "ARITHIGNORE" => self.session_flags[n.to_upper()] = on
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
