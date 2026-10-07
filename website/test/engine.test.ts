import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execute, reset } from '../src/generated/engine.js';
import type { QueryResult } from '../src/protocol.ts';
import { examples } from '../src/examples.ts';
const query = (sql: string): QueryResult => JSON.parse(execute(sql, Date.UTC(2026, 9, 7)));
// SQL results and error expectations come from checked-in SQL Server captures.
for (const name of ['select-1', 'select-named', 'empty-result', 'multiple-sets', 'invalid-object', 'print', 'raiserror-16']) {
  test(`browser executor matches SQL Server capture: ${name}`, () => {
    reset();
    const base = new URL(`../../harness/corpus/smoke/${name}`, import.meta.url);
    const sql = readFileSync(`${base.pathname}.sql`, 'utf8');
    const capture = JSON.parse(readFileSync(`${base.pathname}.expected.json`, 'utf8')).steps[0];
    const actual = query(sql);
    assert.deepEqual(actual.sets.map(s => ({ columns: s.columns, rows: s.rows })), capture.sets.map((s: { columns: { name: string }[]; rows: unknown[][] }) => ({
      columns: s.columns.map(c => c.name), rows: s.rows.map(row => row.map(v => v === null ? null : String(v))),
    })));
    assert.deepEqual(actual.messages.filter(m => m.severity >= 11).map(m => m.number), capture.errors.map((e: { number: number }) => e.number));
    assert.equal(actual.interrupted, false);
  });
}
test('all advertised examples execute in the JS engine', () => {
  reset();
  for (const example of examples) {
    const result = query(example.sql);
    assert.deepEqual(result.messages.filter(m => m.severity >= 11), [], example.name);
    assert.ok(result.sets.length > 0, example.name);
  }
});
test('reset discards state; sessions otherwise persist across calls', () => {
  reset();
  query('CREATE TABLE persist (id int); INSERT INTO persist VALUES (1)');
  assert.equal(query('SELECT * FROM persist').sets[0].rows.length, 1);
  reset();
  assert.ok(query('SELECT * FROM persist').messages.some(m => m.severity >= 11));
});
test('a scheduled wait is reported as incomplete and resets state', () => {
  reset();
  query('CREATE TABLE before_wait (id int)');
  assert.equal(query("WAITFOR DELAY '00:00:01'").interrupted, true);
  assert.ok(query('SELECT * FROM before_wait').messages.some(m => m.severity >= 11));
});
test('bigint crosses JS boundary without losing precision (SQL Server capture)', () => {
  reset();
  const base = new URL('../../harness/corpus/analytic/generate-series', import.meta.url).pathname;
  const batches = readFileSync(`${base}.sql`, 'utf8').split(/-- @step batch\s*\n/).slice(1);
  const index = batches.findIndex(sql => sql.includes('9223372036854775807'));
  const expected = JSON.parse(readFileSync(`${base}.expected.json`, 'utf8')).steps[index];
  assert.deepEqual(query(batches[index]).sets[0].rows, expected.sets[0].rows);
});
test('browser clock converts Unix milliseconds into core ticks', () => {
  reset();
  const instant = Date.UTC(2026, 9, 7, 12, 34, 56);
  const result: QueryResult = JSON.parse(execute('SELECT SYSUTCDATETIME() AS now', instant));
  assert.equal(Date.parse(result.sets[0].rows[0][0] + 'Z'), instant);
});
