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
