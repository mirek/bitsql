import { test } from 'node:test'
import assert from 'node:assert/strict'
import { normalizeQueryStoreDatabaseIds } from '../src/capture-core.mjs'

test('Query Store normalization preserves plan IDs, user values and unrelated errors', () => {
  const message = 'Query plan with provided plan_id (123) is not found in the Query Store for database (17).'
  const input = { steps: [{ errors: [{ number: 12403, message }, { number: 50000, message }], sets: [{ rows: [[message]] }] }] }
  const actual = normalizeQueryStoreDatabaseIds(input)
  assert.equal(actual.steps[0].errors[0].message, message.replace('(17)', '({dbid})'))
  assert.deepEqual(actual.steps[0].errors[1], input.steps[0].errors[1])
  assert.deepEqual(actual.steps[0].sets, input.steps[0].sets)
  assert.equal(input.steps[0].errors[0].message, message)
})
