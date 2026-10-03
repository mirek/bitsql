// Shared helpers for client tests (run through `npm test`, see src/test.mjs).
import { emulatorConfig, fixedAddress, spawnEmulator } from '../src/emulator.mjs'

export const REQUIRE = process.env.BITSQL_REQUIRE === '1'

// One emulator per test file: BITSQL_ADDR when set, else a spawned BITSQL_BIN.
export async function server(t) {
  const fixed = fixedAddress()
  if (fixed) return { ...fixed, config: emulatorConfig(fixed) }
  const s = await spawnEmulator({ bin: process.env.BITSQL_BIN })
  t.after(() => s.stop())
  return { ...s, config: emulatorConfig(s) }
}

// Explicit "not supported" errors from the emulator (Emulator: …, 50100–50199).
export function isUnsupported(error) {
  const list = error?.errors ?? [error]
  return list.some(e => e && ((e.number >= 50100 && e.number <= 50199) || /^Emulator:/.test(e.message ?? '')))
}

// Skips the test on an explicit unsupported error unless BITSQL_REQUIRE=1.
export function skipIfUnsupported(t, errorOrCapture) {
  const errors = errorOrCapture?.errors && !(errorOrCapture instanceof Error) ? errorOrCapture.errors : [errorOrCapture]
  const hit = errors.find(e => isUnsupported(e))
  if (hit && !REQUIRE) { t.skip(`unsupported: ${hit.message}`); return true }
  return false
}
