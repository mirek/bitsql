import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

// The start function runs every top-level initializer; array literals there
// compile to code per element. At 932 KB it cost 7.5 MB of machine code per
// process and a 2 GB optimizing compile (decisions.md 2026-10-26): keep large
// tables as text (src/core/tabletext).
test('the module start function stays small', () => {
  const b = readFileSync(new URL('../bitsql.wasm', import.meta.url))
  let p = 8
  const leb = () => { let r = 0, s = 0, x; do { x = b[p++]; r += (x & 0x7f) * 2 ** s; s += 7 } while (x & 0x80); return r }
  let start, imports = 0, size
  while (p < b.length) {
    const id = b[p++], len = leb(), end = p + len
    if (id === 2) assert.equal(leb(), 0, 'the module imports nothing')
    if (id === 8) start = leb()
    if (id === 10) {
      const n = leb()
      for (let i = 0; i < n; i++) { const sz = leb(); if (imports + i === start) size = sz; p += sz }
    }
    p = end
  }
  assert.ok(size !== undefined, 'start function found')
  assert.ok(size < 128 * 1024, `start function is ${size} bytes`)
})
