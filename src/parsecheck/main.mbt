///|
/// Parses SQL scripts (split on GO like sqlcmd/SSMS) and reports every batch
/// that fails to parse. Use it to measure parser coverage of a codebase.
///
/// Usage: parsecheck FILE... [--quiet]
/// Exit summary: "N batches, M failed". Failures print FILE:LINE: message.
async fn main {
  let args = @env.args()[1:].to_owned()
  let quiet = args.contains("--quiet")
  // --json FILE: FILE holds a JSON array of batch texts; print one line per
  // batch: "ok" or "<number> <line> <message>" (harness parse differential).
  match args.search("--json") {
    Some(i) if i + 1 < args.length() => {
      let json = @json.parse(@fs.read_file(args[i + 1]).text())
      guard json is Array(items) else { fail("--json expects an array") }
      for item in items {
        guard item is String(sql) else { continue }
        let line = try {
          ignore(@parse.parse_batch(sql))
          "ok"
        } catch {
          e => "\{e.number()} \{e.line()} \{e.message()}"
        }
        @stdio.stdout.write(line + "\n")
      }
      return
    }
    _ => ()
  }
  let mut batches = 0
  let mut failed = 0
  for path in args {
    if path.has_prefix("--") {
      continue
    }
    let text = @fs.read_file(path).text()
    let mut line_base = 0
    for batch in @lex.split_go_batches(text) {
      batches += 1
      try @parse.parse_batch(batch) catch {
        e => {
          failed += 1
          if !quiet {
            @stdio.stdout.write(
              "\{path}:\{line_base + e.line()}: \{e.render()}\n",
            )
          }
        }
      } noraise {
        _ => ()
      }
      line_base += batch.split("\n").count() // approximate: GO lines shift this
    }
  }
  @stdio.stdout.write("\{batches} batches, \{failed} failed\n")
  @async.sleep(0)
}
