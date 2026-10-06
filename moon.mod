// MoonBit module descriptor. See docs/moonbit/toolchain/moon-module.md
name = "mirek/bitsql"

version = "0.1.14"

readme = "README.md"

repository = "https://github.com/mirek/bitsql"

license = "CC0-1.0"

keywords = [ "sql", "tsql", "mssql", "tds", "emulator" ]

description = "Memory-only SQL Server emulator speaking TDS, written in MoonBit"

preferred_target = "native"

source = "src"

import {
  "moonbitlang/async@0.22.4",
}

// implicit_impl_as_method fires on every `derive` of a pub type; we never call
// derived trait methods as plain methods, so the migration warning is noise.

warnings = "-implicit_impl_as_method"
