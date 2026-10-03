///|
/// Temporary executor until the parser/binder/executor land: accepts batches
/// made only of SET statements (tedious sends one right after login) and
/// answers everything else with an explicit emulator error, never a fake
/// result.
pub fn stub_executor() -> Executor {
  {
    run: (_, req) => {
      match req {
        SqlBatch(text) if only_set_statements(text) => []
        _ =>
          [
            Message({
              number: 50100,
              state: 1,
              class: 16,
              message: "Emulator: SQL execution is not implemented yet",
              procedure: "",
              line: 1,
            }),
          ]
      }
    },
  }
}

///|
fn only_set_statements(text : String) -> Bool {
  let mut saw = false
  for line in text.split("\n") {
    let t = line.trim().to_owned().to_lower()
    if t == "" {
      continue
    }
    if !t.has_prefix("set ") {
      return false
    }
    saw = true
  }
  saw
}
