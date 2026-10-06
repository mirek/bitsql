import { test } from 'node:test'
import assert from 'node:assert/strict'
import { toExpected } from '../src/runner.mjs'

const reset = { client: true, code: 'ECONNRESET', message: 'socket hang up', number: null }
const closed = { client: true, code: 'EINVALIDSTATE', message: 'Requests can only be made in the LoggedIn state, not the Final state', number: null }
const result = { case: 'capture', steps: [{ errors: [reset] }], reuse: { errors: [closed] } }

test('disconnect capture requires an explicit per-step opt-in', () => {
  assert.match(toExpected({ steps: [{}] }, result).error, /socket hang up/)
  const captured = toExpected({ steps: [{ captureDisconnect: true }] }, result)
  assert.deepEqual(captured.expected.steps, result.steps)
  assert.deepEqual(captured.expected.reuse, result.reuse)
})

test('disconnect opt-in does not accept timeouts or another connection losing primary reuse', () => {
  const timeout = { ...result, steps: [{ errors: [{ client: true, code: 'ETIMEOUT', message: 'timeout' }] }] }
  assert.match(toExpected({ steps: [{ captureDisconnect: true }] }, timeout).error, /timeout/)
  assert.match(toExpected({ steps: [{ captureDisconnect: true, conn: 2 }] }, result).error, /LoggedIn/)
})
