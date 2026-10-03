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
  let word = () => {
    match value {
      Word(w) => w.to_lower()
      ValueExpr(e) =>
        match self.eval(e).0 {
          String(s) => s.to_lower()
          _ => ""
        }
      _ => ""
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
      "ANSI_NULLS"
      | "ANSI_PADDING"
      | "ANSI_WARNINGS"
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
        match number() {
          Some(d) if d >= 1 && d <= 7 => self.rt.datefirst = d
          _ => raise unsupported(n)
        }
        cmd = Some(249)
      }
      "DATEFORMAT" => {
        if word() != "mdy" {
          raise unsupported(n)
        }
        cmd = Some(249)
      }
      "LANGUAGE" => {
        let lang = word()
        if lang != "us_english" && lang != "english" {
          raise unsupported(n)
        }
        // captured: ENVCHANGE language, INFO 5703, DONE 249
        self.out.push(EnvChange(Language("us_english", "us_english")))
        self.info(5703, 1, "Changed language setting to us_english.", line)
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
