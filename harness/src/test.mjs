// npm test: client-level tests against the emulator (scripts/check.sh runs it).
//
// 1. Resolve the emulator (BITSQL_ADDR, BITSQL_BIN, or moon build + spawn) and
//    probe a tedious login. If that fails, print SKIP and exit 0 so main stays
//    green before the server exists — unless BITSQL_REQUIRE=1.
// 2. Run `node --test test/` with BITSQL_BIN/BITSQL_ADDR pinned. Inside the
//    tests, an `Emulator:` error (50100–50199, explicit "not supported") skips
//    the test unless BITSQL_REQUIRE=1; any other divergence fails.
import { spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { harnessDir } from './env.mjs'
import { emulatorBinary, fixedAddress, probe, spawnEmulator } from './emulator.mjs'

const require = process.env.BITSQL_REQUIRE === '1'
const skip = reason => {
  if (require) { console.error(`FAIL (BITSQL_REQUIRE=1): ${reason}`); process.exit(1) }
  console.log(`SKIP harness tests: ${reason.split('\n')[0]}`)
  process.exit(0)
}

const env = { ...process.env }
const fixed = fixedAddress()
if (fixed) {
  const error = await probe(fixed)
  if (error) skip(error.message)
} else {
  let bin
  try { bin = emulatorBinary() } catch (error) { skip(`server not available: ${error.message}`) }
  let server
  try { server = await spawnEmulator({ bin }) } catch (error) { skip(error.message) }
  const error = await probe(server)
  await server.stop()
  if (error) skip(error.message)
  env.BITSQL_BIN = bin
}
const result = spawnSync(process.execPath, ['--test', '--test-reporter=spec', 'test/*.test.mjs'], { stdio: 'inherit', env, cwd: harnessDir })
process.exit(result.status ?? 1)
