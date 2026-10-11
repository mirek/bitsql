// The contracts leave one fact to tests: civil_from_days gives February 29
// only in leap years (SMT solvers time out on it). The domains are finite,
// so these loops check every value, which also covers the round trips.

///|
fn leap(y : Int) -> Bool {
  (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

///|
fn month_days(y : Int, m : Int) -> Int {
  match m {
    2 => if leap(y) { 29 } else { 28 }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
}

///|
test "every day 0001-01-01 .. 9999-12-31 is a valid date and round-trips" {
  let mut prev = (1, 1, 0)
  for days in 0..<=3652058 {
    let (y, m, d) = @proved.civil_from_days(days)
    // the successor of the previous date
    let (py, pm, pd) = prev
    let next = if pd < month_days(py, pm) {
      (py, pm, pd + 1)
    } else if pm < 12 {
      (py, pm + 1, 1)
    } else {
      (py + 1, 1, 1)
    }
    if (y, m, d) != next || @proved.days_from_civil(y, m, d) != days {
      fail("day \{days}: \{y}-\{m}-\{d}")
    }
    prev = (y, m, d)
  }
  debug_inspect(prev, content="(9999, 12, 31)")
}

///|
test "every datetime unit of a day round-trips through ticks" {
  for units in 0..<25_920_000 {
    let u = units.to_int64()
    if @proved.ticks_to_datetime_units(@proved.datetime_units_to_ticks(u)) != u {
      fail("units \{units}")
    }
  }
}

///|
test "datetime_parts carries the last 1/600 s of a day into the next day" {
  let day = 864_000_000_000L
  // from 23:59:59.9983334 on (299.5 units of the last second) it rounds up
  debug_inspect(@proved.datetime_parts(day + day - 16_666L), content="(2, 0)")
  debug_inspect(
    @proved.datetime_parts(day + day - 16_667L),
    content="(1, 25919999)",
  )
  debug_inspect(@proved.datetime_parts(day - 1L), content="(1, 0)")
  debug_inspect(@proved.ticks_to_datetime_units(day - 1L), content="25920000")
}
