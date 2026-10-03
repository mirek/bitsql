///|
/// SQL Server rejects an unknown datepart while parsing: 155 "'x' is not a
/// recognized dateadd option." (captured: functions/date fortnight cases).
fn check_datepart(
  name : @ast.ObjectName,
  args : Array[@ast.Expr],
) -> Unit raise @ast.SyntaxError {
  if name.parts.length() != 1 || args.length() == 0 {
    return
  }
  let fname = name.base().to_lower()
  guard fname
    is ("dateadd"
    | "datediff"
    | "datediff_big"
    | "datepart"
    | "datename"
    | "datetrunc") else {
    return
  }
  guard args[0].kind is Column([id]) else { return }
  let known = id.name.to_lower()
    is ("year"
    | "yy"
    | "yyyy"
    | "quarter"
    | "qq"
    | "q"
    | "month"
    | "mm"
    | "m"
    | "dayofyear"
    | "dy"
    | "y"
    | "day"
    | "dd"
    | "d"
    | "week"
    | "wk"
    | "ww"
    | "weekday"
    | "dw"
    | "w"
    | "hour"
    | "hh"
    | "minute"
    | "mi"
    | "n"
    | "second"
    | "ss"
    | "s"
    | "millisecond"
    | "ms"
    | "microsecond"
    | "mcs"
    | "nanosecond"
    | "ns"
    | "iso_week"
    | "isowk"
    | "isoww"
    | "tzoffset"
    | "tz")
  if !known {
    raise syntax_error(
      155,
      "'\{id.name}' is not a recognized \{fname} option.",
      id.span,
    )
  }
}
