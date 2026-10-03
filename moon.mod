// MoonBit module descriptor. See docs/moonbit/toolchain/moon-module.md
name = "mirek/bitsql"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/mirek/bitsql"

keywords = [ "sql", "tsql", "mssql", "tds", "emulator" ]

description = "Memory-only SQL Server emulator speaking TDS, written in MoonBit"

preferred_target = "native"

source = "src"

import {
  "moonbitlang/async@0.22.4",
}
