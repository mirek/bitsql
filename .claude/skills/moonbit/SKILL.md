---
name: moonbit
description: Writing, building and testing MoonBit code in bitsql — where the vendored language/toolchain/API docs are, repo conventions (pure core vs async host, package layout, moon.pkg DSL, tests), commands, and accumulated gotchas. Use before writing or refactoring any .mbt file, adding a package, or when a moon/moonc error is unclear.
---

# MoonBit in bitsql

## Where to look things up (in order)

1. **This file's gotchas** (bottom). They are hard-won and repo-specific.
2. `docs/moonbit/agent-guide/SKILL.md` and `moonbit-language-fundamentals.md`:
   the official agent guide, a dense language cheat sheet.
3. `docs/moonbit/language/*.md`: the full language reference
   (`fundamentals.md`, `methods.md`, `error-handling.md`, `packages.md`,
   `tests.md`, `derive.md`, `attributes.md`).
4. `docs/moonbit/core-api/<pkg>.mbti`: exact stdlib signatures
   (`builtin.mbti` holds Array/String/Bytes/Map/StringBuilder…;
   `INDEX.md` lists packages). `grep -n 'fn.*name' docs/moonbit/core-api/*.mbti`
   beats guessing.
5. `docs/moonbit/async/api.md`: moonbitlang/async API (host only).
6. `moon doc <Symbol>` and `moon ide peek-def/outline` (see
   `docs/moonbit/agent-guide/ide.md`).
7. `moon explain <code>` for any diagnostic number.

Versions are in `docs/moonbit/VERSIONS.md`. If the compiler disagrees with the
docs, the compiler wins: refresh docs (skill `moonbit-docs-update`) and/or add a
gotcha below.

## Repo conventions

- Module `mirek/bitsql`, `source = "src"`. Package `src/core/tds` is imported
  as `"mirek/bitsql/core/tds"` and used as `@tds.xxx`.
- **`src/core/**` is pure.** No `moonbitlang/async`, no FFI, no clock, no
  randomness, no printing. Time and seeds arrive via `Event`/`Engine::new`.
  `moon check --target all` must pass for core packages. Only `src/host` may
  import async.
- Package files use the `moon.pkg` DSL (`import { "..." }`, `pkgtype(...)`,
  `supported_targets = "+native"`), never `moon.pkg.json`.
- Every top-level item starts with `///|`. Keep files focused (one concept per
  file); many small files are idiomatic.
- Tests: black-box `*_test.mbt` by default, `*_wbtest.mbt` only for private
  internals. Snapshot with `inspect(x, content="...")` / `debug_inspect`, refresh
  with `moon test -u` and *review the diff*. Byte-level codec tests compare hex
  strings, so failures are readable.
- Errors: `suberror` types per package; avoid bare `raise` (untyped) in public
  APIs of core packages.
- After changing a package's public API: `moon info` (regenerates
  `pkg.generated.mbti`, which is committed) and `moon fmt`. Review the `.mbti`
  diff: it is the API contract.
- Prefer `Bytes`/`BytesView` for wire data and `@buffer.Buffer` for building
  output. Strings are UTF-16 internally, which matches TDS's UCS-2 well.

## Commands

```bash
moon check                       # fast type check (preferred target native)
moon check --target all          # core purity / portability check
moon test                        # all tests (native)
moon test -p mirek/bitsql/core/tds   # one package
moon test -u                     # update snapshots
moon build && ./_build/native/debug/build/host/host.exe   # (path: see scripts/run.sh)
moon info && moon fmt            # before committing API changes
scripts/check.sh                 # everything CI runs; must be green to push
```

## Gotchas and learnings (append, dated)

- 2026-10-03: toolchain moon 0.1.20260920 / moonc v0.10.14 uses `moon.mod` and
  `moon.pkg` (DSL) by default; `moon new` scaffolds them. Feature flags
  `rr_moon_mod,rr_moon_pkg` are on.
- 2026-10-03: `async fn main` without any `await`-style call warns
  `unused_async` (0067); unused imports warn 0029. Warnings do not fail
  the build, but keep the tree warning-free.
- 2026-10-03: building moonbitlang/async on Linux prints a C warning
  (`ignoring return value of 'write'` in thread_pool.c). Harmless and upstream.
- 2026-10-03: deprecated in moonc v0.10.14: `derive(Show)` (use `derive(Debug)`
  + `debug_inspect`, or `@debug.to_string(x)` for messages); `try?` (tests:
  `try f() catch { e => ... } noraise { _ => fail("...") }`); `@buffer.new()` /
  `StringBuilder::new()` (use `Buffer()` / `StringBuilder()`);
  `Int64::to_uint64` (use `reinterpret_as_uint64`); `Double::to_float` (use
  `Float::from_double`); `Int::reinterpret_as_float` (use
  `Float::reinterpret_from_int`); `StringView::to_string` (use `to_owned`).
- 2026-10-03: `{}` as an empty Map is ambiguous (warning 0082): write `Map([])`.
- 2026-10-03: warning 0079 `implicit_impl_as_method` fires on any `derive` of a
  pub type; disabled module-wide in `moon.mod` (`warnings = "-implicit_impl_as_method"`).
- 2026-10-03: a `pub struct` cannot have a field of a `priv` type (error 4046).
  Make the outer struct abstract (plain `struct`) instead. Raising a variant of
  another package's error requires that error to be `pub(all) suberror`.
- 2026-10-03: `"\{x:?}"` debug interpolation does not exist; use
  `\{@debug.to_string(x)}` (import `moonbitlang/core/debug`).
- 2026-10-03: test-only imports in `moon.pkg`: `import { "pkg" } for "test"`.
- 2026-10-03: `Int::to_string(radix=16)` for hex; there is no `to_hex`.
- 2026-10-03: the functional `loop x { pat => ... continue y }` form is
  **deprecated** in moonc v0.10.14 (warning 0027), although the vendored agent
  guide still teaches it. Write `for n = init { match n { ... => continue next;
  ... => break result } }` instead.
- 2026-10-03: `Set::new()` is deprecated: write `let s : Set[Int] = Set([])`.
- 2026-10-03: a constructor with labelled fields needs its positional args in
  patterns too: `KeyRange(table~, _, ..)`, not `KeyRange(table~, ..)`.
- 2026-10-03: generic `==` on a type parameter needs `K : Eq`. For
  comparator-based containers, pass `(K, K) -> Int` and write `same(a, b, cmp)`
  helpers rather than adding trait bounds.
- 2026-10-03: a record literal of another package's struct needs a known
  expected type: `out.push({ name, desc })` on an un-annotated `[]` fails with
  4033 "There is no record definition with the fields". Annotate the array
  (`let out : Array[@ast.IndexColumn] = []`) or write `@ast.Identity::{ ... }`.
- 2026-10-03: `declare` and `readonly` are keywords (method `Parser::declare`
  is a parse error); `alias` and `include` warn 0035 (reserved for future use).
  Use `declare_stmt`, `read_only`, `alias_`, `included`.
- 2026-10-03: `const` only takes immutable primitives; `const X : FixedArray[..]`
  is error 4143. Use a top-level `let` (initialiser may be a block `{ ... }`).
- 2026-10-03: a match guard must stay on the pattern line
  (`"A" | "B" if cond =>`); breaking before `if` is a parse error.
- 2026-10-03: passing a `#|` multi-line string directly as an argument is
  deprecated; wrap it in parentheses: `f((\n #|...\n))`. `moon test -u` writes
  snapshots containing `\r` raw into `#|` blocks and corrupts the file: escape
  CRs before `inspect`.
- 2026-10-03: `String::trim_space` is deprecated (use `trim()`); `inspect` on an
  `Array` warns (Show-for-debugging deprecated), use `debug_inspect`; mixing
  `&&` and `||` without parentheses warns 0051; a function declared `raise E`
  that never raises warns 0024.
- 2026-10-03: `f() catch { e => .. } noraise { v => .. }` is the expression form
  of error handling (moon fmt rewrites it to `try f() catch ...`). Local
  closures may raise: `let check = fn(x : String) raise E { ... }`. Struct
  patterns nest enums and arrays: `{ body: Nested(q), order_by: [], .. }`.
- 2026-10-03: a recursive-descent parser on `Array[Token]` with a `mut pos`
  and save/restore backtracking (`try { ... } catch { _ => None }`) is simple
  and fast: 10k statements parse in well under a second natively.
- 2026-10-03: `@bigint.BigInt` `/` and `%` truncate toward zero like `Int`
  (-7/2 = -3, -7%2 = -1, checked in a scratch test). There is no
  `BigInt::from_double`; build exact values from the IEEE bits
  (src/core/types/decimal.mbt `from_double_exact`).
- 2026-10-03: `s[a:b]` on String/StringView snaps boundaries away from
  surrogate halves; for exact UTF-16 code-unit slicing (lone surrogates are
  valid nvarchar data) use `s.unsafe_substring(start=a, end=b)` after your own
  bounds check. Build strings with lone surrogates via
  `StringBuilder::write_char(unit.unsafe_to_char())`.
- 2026-10-03: deprecated in moonc 0.10.14 (warning 0020): `String::substring`
  (use views / `unsafe_substring`), `Char::from_int` (`Int::unsafe_to_char`),
  `UInt64::to_int64` (`reinterpret_as_int64`), `Double::to_float`
  (`Float::from_double`), `UInt::reinterpret_as_float`
  (`Float::reinterpret_from_uint`), `|> fn(x) {..}` (`|> x => ..`). A
  `fn() { .. }` lambda that raises warns 0027: write `() => expr`.
- 2026-10-03: local closures cannot take labelled/optional parameters
  (error 4114): make such helpers toplevel. `suberror E T` (newtype form) does
  not parse; declare `suberror E { A; B }`. `local` is a reserved word
  (warning 0035).
- 2026-10-03: two enums in one package sharing constructor names (e.g.
  `Value::Binary` and `SqlType::Binary`) are ambiguous where no type is
  expected (error 4124); qualify as `@types.Value::Binary(..)`. Interpolating
  an `Array[Int]` uses the deprecated Show impl (warning) and
  `moon check --deny-warn` covers test files too.
- 2026-10-03: big generated test tables (1–2k tuple literals) compile fine
  and keep capture-derived tests readable; generate them with a script and
  say so in the file header.
- 2026-10-03: `errdefer { <stmts> }` (braces needed for assignments) runs cleanup only when the rest of the block
  raises; the compiler flags `catch { e => { cleanup; raise e } }` (warning
  0092) and suggests it.
- 2026-10-03: `typealias X as Y` from older docs is gone; write
  `pub type Row = Array[Value]`.
- 2026-10-03: `moon fmt` adds trailing commas to one-line record literals and
  re-wraps long calls. Scripted text edits against formatted code must match
  that (or replace whole blocks between stable markers).
- 2026-10-03 (shell, not MoonBit): never `pkill -f '<pattern>'` with a
  pattern that also appears in the running shell's own command line; it
  kills the shell (exit 144). Keep the server PID (`cmd & HP=$!; kill $HP`).
- 2026-10-03: **an abort is a server outage.** `String::repeat` with a huge
  count, out-of-bounds `arr[i]`, `Bytes::make(huge)`, `unwrap()` on None and
  similar abort the whole process, killing every session. Never pass
  user-controlled sizes or indexes to them unclamped (REPLICATE/SPACE/
  RAISERROR width crashed this way). Clamp, use `get()`, or raise a SqlError.
  The harness reports such crashes as `client error: ECONNRESET`.
- 2026-10-03: transcendental math lives in `@math` (`@math.exp/ln/log10/sin/
  atan2/pow`, `@math.PI`); `Double::pow` is deprecated and there is no
  `Double::exp`/`ln`. `@double.not_a_number` for NaN. `BigInt` has no `abs`.
  A local variable named `local` warns 0035 (reserved). Constructors of
  another package's enum used as a value in an `if` expression need the type
  (`let t : @types.SqlType = if c { Float } else { … }` — otherwise "using
  constructors as higher order function").

- 2026-10-03: a type alias cannot be `priv` (`priv type X = Map[..]` warns
  0027 deprecated visibility); write `type X = Map[..]`. `Ref::new` is
  deprecated; a closure may assign a captured `let mut` directly. A struct
  field of closure type may raise: `(A) -> B? raise @types.SqlError`.
- 2026-10-03: tuple patterns take no `..` rest (`let (a, b, ..) = t` is a
  parse error on a 10-tuple): spell out every position with `_`. Generated
  data tables (`Array[(Int64, Int, Int, Bool)]`, ~650 rows) and test tables
  (~11k rows) compile quickly.
