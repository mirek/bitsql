// Corpus cases that gate `npm test`: everything under corpus/smoke plus the
// selectors listed in harness/allowlist.txt. A case whose emulator run hits
// an explicit `Emulator:` error is skipped (unless BITSQL_REQUIRE=1); any
// other difference from the captured SQL Server output fails.
import { test, after } from 'node:test'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { harnessDir, useUtcTimeZone } from '../src/env.mjs'
import { loadCorpus, readExpected } from '../src/corpus.mjs'
import { emulatorTarget, runCase } from '../src/runner.mjs'
import { compareCase } from '../src/compare.mjs'
import { isUnsupported, REQUIRE } from './support.mjs'

useUtcTimeZone()
const allowlist = (await readFile(join(harnessDir, 'allowlist.txt'), 'utf8').catch(() => ''))
  .split('\n').map(l => l.replace(/\s+#\s.*$/, '').trim()).filter(l => l && !l.startsWith('#'))
const cases = await loadCorpus(['smoke', ...allowlist])
const target = await emulatorTarget()

for (const c of cases) {
  test(`corpus ${c.id}`, async t => {
    const expected = await readExpected(c)
    if (!expected) { t.skip('no captured expectation'); return }
    const actual = await runCase(target, c)
    const failure = compareCase(actual, expected)
    if (!failure) return
    const errors = [...(actual.steps ?? []), actual.reuse].flatMap(s => s?.errors ?? [])
    if (!REQUIRE && errors.some(isUnsupported)) { t.skip(`unsupported: ${errors.find(isUnsupported).message}`); return }
    throw new Error(`${failure.kind} at ${failure.path}: actual ${JSON.stringify(failure.actual)?.slice(0, 300)} expected ${JSON.stringify(failure.expected)?.slice(0, 300)}`)
  })
}
after(() => target.stop?.())
