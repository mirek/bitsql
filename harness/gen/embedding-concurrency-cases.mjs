// The HTTPS reply is held until the second connection completes its mutation.
export const embeddingConcurrencyCases = [
  { name: 'source-update', setup: "CREATE TABLE t(id int PRIMARY KEY,s nvarchar(100)); INSERT t VALUES(1,N'first');", mutation: "UPDATE t SET s=N'changed';" },
  { name: 'source-delete', setup: "CREATE TABLE t(id int PRIMARY KEY,s nvarchar(100)); INSERT t VALUES(1,N'first');", mutation: 'DELETE t;' },
  { name: 'unread-update', mutation: "UPDATE t SET s=N'changed' WHERE id=2;" },
  { name: 'unread-delete', mutation: 'DELETE t WHERE id=2;' },
  { name: 'unread-insert', mutation: "INSERT t VALUES(3,N'third');" },
  { name: 'model-drop', mutation: 'DROP EXTERNAL MODEL m;' },
  { name: 'model-alter', mutation: "ALTER EXTERNAL MODEL m SET(MODEL='changed');" },
  { name: 'table-drop', mutation: 'DROP TABLE t;' },
  { name: 'rest-disable', mutation: "EXEC sp_configure 'external rest endpoint enabled',0; RECONFIGURE;" },
].map(c => ({
  setup: "CREATE TABLE t(id int PRIMARY KEY,s nvarchar(100)); INSERT t VALUES(1,N'first'),(2,N'second');",
  sql: 'SELECT id,s,AI_GENERATE_EMBEDDINGS(s USE MODEL m) AS embedding FROM t ORDER BY id;',
  ...c,
}))


// Completed statements must stay committed while a later expression waits.
export const embeddingPrefixCases = [
  { name: 'prefix-visible', mutation: 'SELECT id,s FROM t ORDER BY id;' },
  { name: 'prefix-unique', mutation: "INSERT t VALUES(2,N'concurrent');" },
  { name: 'prefix-variables', sql: "DECLARE @s nvarchar(100)=N'prefix'; INSERT t VALUES(2,@s); SELECT AI_GENERATE_EMBEDDINGS(@s USE MODEL m) AS embedding; SELECT @s AS retained;", mutation: 'SELECT id,s FROM t ORDER BY id;' },
  { name: 'prefix-following-wait', sql: "INSERT t VALUES(2,N'prefix'); SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding; WAITFOR DELAY '00:00:00.01'; SELECT id,s FROM t ORDER BY id;", mutation: 'SELECT id,s FROM t ORDER BY id;' },
  { name: 'prefix-block', sql: "BEGIN INSERT t VALUES(2,N'prefix'); SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding; END; SELECT id,s FROM t ORDER BY id;", mutation: 'SELECT id,s FROM t ORDER BY id;' },
  { name: 'prefix-table-variable', sql: "DECLARE @t TABLE(id int); INSERT @t VALUES(2); SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding; SELECT id FROM @t;", mutation: 'SELECT id,s FROM t ORDER BY id;' },
  { name: 'prefix-ddl', sql: "CREATE TABLE created_before_http(id int); SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding;", mutation: "SELECT CASE WHEN OBJECT_ID(N'created_before_http') IS NOT NULL THEN 1 ELSE 0 END AS visible;", cleanup: 'DROP TABLE created_before_http;' },
].map(c => ({
  setup: "CREATE TABLE t(id int CONSTRAINT pk_prefix PRIMARY KEY,s nvarchar(100)); INSERT t VALUES(1,N'first');",
  sql: "INSERT t VALUES(2,N'prefix'); SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding;",
  ...c,
}))

export const embeddingRpcPrefixCases = [
  ...embeddingPrefixCases,
  { ...embeddingPrefixCases[0], name: 'rpc-temp-scope', sql: "CREATE TABLE #held(id int); INSERT #held VALUES(2); SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding; SELECT id FROM #held;", after: "SELECT OBJECT_ID(N'tempdb..#held') AS remaining;" },
  { ...embeddingPrefixCases[0], name: 'rpc-settings-scope', sql: "SET NOCOUNT ON; SET DATEFIRST 3; SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding; SELECT @@DATEFIRST AS inside_module;", after: 'SELECT @@DATEFIRST AS outside_module;' },
  { ...embeddingPrefixCases[0], name: 'prefix-output',
    sql: "SET @out=N'prefix'; INSERT t VALUES(2,@out); SELECT AI_GENERATE_EMBEDDINGS(@out USE MODEL m) AS embedding;",
    params: [{ name: 'out', type: 'nvarchar(100)', value: 'initial', output: true }],
  },
].map(c => ({ ...c, kind: 'rpc' }))


export const embeddingProcPrefixCases = embeddingRpcPrefixCases.map(c => ({
  ...c,
  kind: 'proc',
  sql: 'embedding_probe',
  prepare: `CREATE PROCEDURE embedding_probe ${c.params ? '@out nvarchar(100) OUTPUT' : ''} AS ${c.sql}`,
  cleanup: (c.cleanup ?? '') + ' DROP PROCEDURE embedding_probe;',
}))

export const embeddingCancellationCases = [{
  ...embeddingRpcPrefixCases[0], name: 'cancel-rpc-http', cancel: true,
  after: 'SELECT id,s FROM t ORDER BY id;',
}]


embeddingProcPrefixCases.push({
  ...embeddingPrefixCases[0], name: 'prepared-prefix', kind: 'proc', sql: 'sp_prepexec',
  params: [
    { name: 'handle', type: 'int', value: 0, output: true },
    { name: 'params', type: 'nvarchar(max)', value: '@id int' },
    { name: 'stmt', type: 'nvarchar(max)', value: "INSERT t VALUES(@id,N'prefix'); SELECT AI_GENERATE_EMBEDDINGS(CONVERT(nvarchar(100),@id) USE MODEL m) AS embedding;" },
    { name: 'id', type: 'int', value: 2 },
  ],
  after: { output: 'handle', sql: 'EXEC sp_execute {handle},3; SELECT id,s FROM t ORDER BY id;' },
})

export const embeddingCancellationMatrixCases = [
  ['scalar', "SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding;"],
  ['columns', "SELECT 1 AS before_value,AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding,2 AS after_value;"],
  ['coalesce', "SELECT COALESCE(CONVERT(nvarchar(max),AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m)),N'fallback') AS value;"],
  ['two-calls', "SELECT AI_GENERATE_EMBEDDINGS(N'first' USE MODEL m) AS a,AI_GENERATE_EMBEDDINGS(N'second' USE MODEL m) AS b;"],
  ['rows', 'SELECT id,AI_GENERATE_EMBEDDINGS(s USE MODEL m) AS embedding FROM t;'],
  ['aggregate', 'SELECT COUNT(AI_GENERATE_EMBEDDINGS(s USE MODEL m)) AS n FROM t;'],
  ['sorted', 'SELECT s,AI_GENERATE_EMBEDDINGS(s USE MODEL m) AS embedding FROM t ORDER BY s DESC;'],
  ['insert', 'INSERT dest SELECT id,AI_GENERATE_EMBEDDINGS(s USE MODEL m) FROM t;'],
  ['assignment', "DECLARE @j json=AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m); SELECT @j;"],
  ['predicate', 'SELECT id FROM t WHERE AI_GENERATE_EMBEDDINGS(s USE MODEL m) IS NULL;'],
  ['subquery', "SELECT (SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m)) AS embedding;"],
  ['vector', "SELECT CAST(AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS vector(2)) AS embedding;"],
].map(([name, sql]) => ({ name, sql, kind: 'rpc', cancel: true,
  setup: "CREATE TABLE t(id int PRIMARY KEY,s nvarchar(100)); INSERT t VALUES(1,N'first'),(2,N'second'); CREATE TABLE dest(id int,embedding json);",
  mutation: 'SELECT 1 AS alive;', after: 'SELECT COUNT(*) AS remaining FROM dest;', cleanup: 'DROP TABLE dest;',
}))

embeddingCancellationMatrixCases.push(...embeddingCancellationMatrixCases.map(c => ({
  ...c, name: 'batch-' + c.name, kind: 'batch',
})))
for (const [name, sql] of [
  ['aggregate-distinct', 'SELECT COUNT(DISTINCT CONVERT(nvarchar(100),AI_GENERATE_EMBEDDINGS(s USE MODEL m))) AS n FROM t;'],
  ['grouped', 'SELECT id,COUNT(AI_GENERATE_EMBEDDINGS(s USE MODEL m)) AS n FROM t GROUP BY id;'],
  ['union', "SELECT AI_GENERATE_EMBEDDINGS(N'first' USE MODEL m) AS embedding UNION ALL SELECT AI_GENERATE_EMBEDDINGS(N'second' USE MODEL m);"],
  ['insert-output', 'INSERT dest OUTPUT inserted.id,inserted.embedding SELECT id,AI_GENERATE_EMBEDDINGS(s USE MODEL m) FROM t;'],
  ['assignment-select', 'DECLARE @j json; SELECT @j=AI_GENERATE_EMBEDDINGS(s USE MODEL m) FROM t; SELECT @j;'],
  ['nested-subqueries', "SELECT (SELECT AI_GENERATE_EMBEDDINGS(N'first' USE MODEL m)) AS a,(SELECT AI_GENERATE_EMBEDDINGS(N'second' USE MODEL m)) AS b;"],
  ['try', "BEGIN TRY SELECT AI_GENERATE_EMBEDDINGS(N'first' USE MODEL m) AS embedding; END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS caught; END CATCH;"],
  ['transaction', "BEGIN TRAN; INSERT dest VALUES(3,NULL); SELECT AI_GENERATE_EMBEDDINGS(N'first' USE MODEL m) AS embedding; COMMIT;"],
]) embeddingCancellationMatrixCases.push({
  ...embeddingCancellationMatrixCases[0], name, sql,
  after: 'SELECT @@TRANCOUNT AS trancount; SELECT COUNT(*) AS remaining FROM dest; IF @@TRANCOUNT>0 ROLLBACK;',
})


export const embeddingContextCases = [
  ...embeddingConcurrencyCases.filter(c => ['model-drop', 'model-alter', 'rest-disable'].includes(c.name)),
  ...embeddingConcurrencyCases.filter(c => ['model-drop', 'rest-disable'].includes(c.name)).flatMap(c => [
    { ...c, name: c.name + '-single', sql: "SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding;" },
    { ...c, name: c.name + '-cancel', cancel: true, kind: 'rpc', sql: "SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding;" },
  ]),
  { ...embeddingConcurrencyCases[0], name: 'model-api-alter', setup: embeddingConcurrencyCases[2].setup,
    mutation: "ALTER EXTERNAL MODEL m SET(API_FORMAT='Ollama');" },
  { ...embeddingConcurrencyCases[0], name: 'model-parameters-alter', setup: embeddingConcurrencyCases[2].setup,
    mutation: `ALTER EXTERNAL MODEL m SET(PARAMETERS='{"temperature":0.5}');` },
]
