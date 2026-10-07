// Inputs to the controlled oracle capture; never used as expected SQL outputs.
const good = { object: 'list', data: [{ object: 'embedding', index: 0, embedding: [0.25, -0.5, 1] }], model: 'fixture' }
const select = (source = "N'hello'", params = '') => `SELECT AI_GENERATE_EMBEDDINGS(${source} USE MODEL m${params ? ' PARAMETERS ' + params : ''}) AS embedding;`
const json = value => `CAST(N'${JSON.stringify(value).replaceAll("'", "''")}' AS json)`
export const embeddingCases = [
  { name: 'openai', sql: select() },
  { name: 'azure', api: 'Azure OpenAI', sql: select() },
  { name: 'ollama', api: 'Ollama', response: { body: { model: 'fixture', embeddings: [[0.25, -0.5, 1]] } }, sql: select() },
  { name: 'unicode', sourceText: "héllo '世界' 😀\n\t", sql: select("N'héllo ''世界'' 😀' + NCHAR(10) + NCHAR(9)") },
  { name: 'empty-source', sourceText: '', sql: select("N''") },
  { name: 'null-source', sourceText: null, sql: select('CAST(NULL AS nvarchar(max))') },
  { name: 'parameter-dimensions', sql: select(undefined, json({ dimensions: 3 })) },
  { name: 'parameter-override', parameters: { dimensions: 2, user: 'saved' }, sql: select(undefined, json({ dimensions: 3 })) },
  { name: 'parameter-reserved', sql: select(undefined, json({ model: 'override', input: 'override', encoding_format: 'float' })) },
  { name: 'parameter-null', sql: select(undefined, 'NULL') },
  { name: 'parameter-array', sql: select(undefined, json([])) },
  { name: 'model-parameter-array', parameters: [], sql: select() },
  { name: 'retry-zero', sql: select(undefined, json({ sql_rest_options: { retry_count: 0 }, dimensions: 3 })) },
  { name: 'retry-negative', sql: select(undefined, json({ sql_rest_options: { retry_count: -1 } })) },
  { name: 'retry-null', sql: select(undefined, json({ sql_rest_options: { retry_count: null } })) },
  ...['input', 'model', 'encoding_format', 'user', 'Model', 'sql_rest_options'].map(key => ({
    name: `request-key-${key}`, fatal: key === 'sql_rest_options', sql: select(undefined, json({ [key]: 'value' })),
  })),
  ...['OpenAI', 'Azure OpenAI', 'Ollama'].map(api => ({
    name: `request-input-${api}`, api, sql: select(undefined, json({ input: 'override' })),
  })),
  ...[{}, { other: 1 }, { retry_count: 1 }, { retry_count: 11 }, { retry_count: '1' }, { retry_count: true }].map((v, i) => ({
    name: `rest-options-${i}`, sql: select(undefined, json({ sql_rest_options: v })),
  })),
  { name: 'retry-decimal', sql: select(undefined, `CAST(N'{"sql_rest_options":{"retry_count":1.0}}' AS json)`) },
  { name: 'model-retry-invalid', parameters: { sql_rest_options: { retry_count: -1 } }, sql: select() },
  { name: 'override-invalid-model-retry', parameters: { sql_rest_options: { retry_count: -1 } }, sql: select(undefined, json({ sql_rest_options: { retry_count: 0 } })) },
  { name: 'source-escape', sourceText: '/\\<>\u0001', sql: select("N'/\\<>' + NCHAR(1)") },
  ...[1, 2].map(n => ({ name: `retry-http-${n}`, response: { status: 500, headers: { 'Retry-After': '0' }, body: {} }, sql: select(undefined, json({ sql_rest_options: { retry_count: n } })) })),
  { name: 'retry-model-http', parameters: { sql_rest_options: { retry_count: 1 } }, response: { status: 429, headers: { 'Retry-After': '0' }, body: {} }, sql: select() },
  { name: 'retry-model-empty-override', parameters: { sql_rest_options: { retry_count: 1 } }, response: { status: 500, headers: { 'Retry-After': '0' }, body: {} }, sql: select(undefined, json({ sql_rest_options: {} })) },
  { name: 'parameter-escapes', sql: select(undefined, json({ text: '/\\<>\u001b', nested: { path: '/' }, list: ['/'] })) },
  { name: 'source-control', sourceText: '\u001b', sql: select('NCHAR(27)') },
  { name: 'model-escape', model: 'fixture/path', sql: select() },
  { name: 'empty-response', response: { body: '' }, sql: select() },
  { name: 'invalid-json', response: { body: 'not json' }, sql: select() },
  { name: 'missing-data', response: { body: {} }, sql: select() },
  { name: 'empty-data', response: { body: { data: [] } }, sql: select() },
  { name: 'null-data', response: { body: { data: null } }, sql: select() },
  { name: 'missing-embedding', response: { body: { data: [{}] } }, sql: select() },
  { name: 'null-embedding', response: { body: { data: [{ embedding: null }] } }, sql: select() },
  { name: 'string-embedding', response: { body: { data: [{ embedding: 'abc' }] } }, sql: select() },
  { name: 'object-embedding', response: { body: { data: [{ embedding: { a: 1 } }] } }, sql: select() },
  { name: 'empty-embedding', response: { body: { data: [{ embedding: [] }] } }, sql: select() },
  { name: 'mixed-embedding', response: { body: { data: [{ embedding: [1, null, 'x'] }] } }, sql: select() },
  { name: 'two-embeddings', response: { body: { data: [{ index: 1, embedding: [1] }, { index: 0, embedding: [2] }] } }, sql: select() },
  { name: 'ollama-two', api: 'Ollama', response: { body: { embeddings: [[1], [2]] } }, sql: select() },
  { name: 'whitespace-response', response: { body: '{ "data": [ { "embedding": [ 1.0, 2e-2, -0.00 ] } ] }' }, sql: select() },
  ...[
    ['root-array', '[]'], ['root-number', '1'], ['root-string', '"hello"'],
    ['root-null', 'null'], ['outside-overflow', '{"other":1e300,"data":[{"embedding":[1]}]}'],
    ['inside-overflow', '{"data":[{"embedding":[1e300]}]}'],
    ['number-embedding', '{"data":[{"embedding":42}]}'],
    ['uppercase-path', '{"Data":[{"embedding":[1]}]}'],
    ['duplicate-path', '{"data":[{"embedding":[1],"embedding":[2]}]}'],
    ['ollama-missing', '{}'],
  ].map(([name, body]) => ({ name, api: name.startsWith('ollama') ? 'Ollama' : 'OpenAI', response: { body }, sql: select() })),
  ...[201, 202, 204, 206, 301, 302, 304, 400, 401, 403, 404, 408, 409, 413, 415, 422, 429, 500, 502, 503, 504].map(status => ({ name: `http-${status}`, response: { status, body: { error: { message: 'fixture rejection', type: 'fixture' } } }, sql: select() })),
].map(c => {
  const optional = / PARAMETERS CAST\(N?'((?:''|[^'])*)' AS json\)/.exec(c.sql)?.[1].replaceAll("''", "'") ?? null
  return { api: 'OpenAI', response: { body: good }, sourceText: 'hello', optional, ...c }
})
