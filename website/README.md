# bitsql website

A static TypeScript/Vite site with a real bitsql SQL playground, following
[cave's website directory and relative-base setup](https://github.com/mirek/cave/tree/main/website).
No backend, CDN scripts, external fonts, or analytics. Production assets are in
`dist/`; all asset URLs work under `/bitsql/` or a custom domain.

## Develop and verify

Use Node 24.13+, pnpm 11.3.0, and the MoonBit compiler pinned in
[`docs/moonbit/VERSIONS.md`](../docs/moonbit/VERSIONS.md).

```sh
pnpm --dir website install --frozen-lockfile
pnpm --dir website dev                 # localhost:47339
pnpm --dir website test                # Node native test runner, SQL capture checks
pnpm --dir website build               # MoonBit JS + TypeScript + static site
pnpm --dir website exec playwright install chromium
BITSQL_BROWSER_TEST=1 pnpm --dir website test:browser
pnpm --dir website preview             # production build at localhost:47339
```

The browser smoke test uses Node's test runner and Playwright's browser API,
starts/stops its own preview server on port 47339, and writes desktop/mobile
screenshots to ignored `test-artifacts/`. It checks result rendering, HTML
escaping, reset, cancellation, mobile overflow, and GitHub Pages subpath asset loading. The normal test command
skips the browser test unless `BITSQL_BROWSER_TEST=1` is set.

## Engine boundary

`src/browser` in the repository root is a small MoonBit display adapter over
`core/session`. It does not implement SQL. `pnpm engine` builds it for JS and
copies the generated ESM to ignored `src/generated/engine.js`. Vite bundles
that module in a lazily loaded Web Worker; the homepage does not download the
engine until the first query. JS was selected because it runs in current
browsers without a Wasm-GC requirement.

Each worker owns one in-memory database and session. The adapter converts the
browser's Unix milliseconds to the core's 100 ns ticks. Cells cross the boundary
as display strings or JSON null, preserving bigint/decimal precision; metadata
comes from the session's result columns, including for empty results. SQL errors
retain their numbers, severity, and line. DOM rendering uses textContent.

There is no browser TDS connection, HTTP integration, or timer scheduler.
Requests that park for a wait or HTTP reset the database with an explicit
incomplete-request notice. A work budget and a 10-second worker timeout bound
ordinary runaway requests; Stop terminates the worker immediately. Reset also
terminates the worker, reclaiming its state. The table shows the first 200 rows
per set; the engine still executes and materializes the full result. Very large
results can exhaust browser memory, so use the container for large workloads.

## Measurements

`public/benchmark-0.1.24.json` is copied unchanged from the recorded
`harness/out/bench-compare-0.1.24.json` run. Chart bars and ratios derive from
those values, with each pair sharing a linear scale starting at zero. The page
includes the slower point-read result and the cold-start sample limitation.
See the root README and `docs/design/performance.md` for reproduction commands.
On a measured release update, replace the evidence file and update the version,
headline figures and methodology together. Do not substitute browser timings
for the container comparison.

## GitHub Pages

`.github/workflows/pages.yml` builds, tests and uploads `website/dist`, then
publishes through the `github-pages` environment. In the repository's
**Settings → Pages → Build and deployment → Source**, select **GitHub Actions**.
Then run **Deploy website** from Actions (or push a website change to main).
The URL is https://mirek.github.io/bitsql/ . No branch containing generated
files is needed. The workflow is scoped to website publishing; the local
`scripts/check.sh` remains the gate for the full emulator/client suite.

The workflow pins the same compiler/core version as the repository and runs
on native amd64. The archive binaries need executable permissions restored
before invoking `moon`; the workflow does this before bundling the JS core.
MoonBit's versioned binary archives have a retention window;
when refreshing the pinned toolchain, update the workflow and vendored docs
together. The workflow must successfully build before deployment is attempted.
