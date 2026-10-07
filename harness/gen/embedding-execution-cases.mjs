// SQL inputs; results and HTTP exchanges are captured from the dedicated oracle.
export const embeddingExecutionCases = [
  { name: 'two-calls', sql: "SELECT AI_GENERATE_EMBEDDINGS(N'first' USE MODEL m) AS a; SELECT AI_GENERATE_EMBEDDINGS(N'second' USE MODEL m) AS b;" },
  { name: 'two-columns', sql: "SELECT AI_GENERATE_EMBEDDINGS(N'first' USE MODEL m) AS a, AI_GENERATE_EMBEDDINGS(N'second' USE MODEL m) AS b;" },
  { name: 'volatile-guid', volatileSource: true, sql: "DECLARE @s nvarchar(36)=CONVERT(nvarchar(36),NEWID()); SELECT @s AS source, AI_GENERATE_EMBEDDINGS(@s USE MODEL m) AS embedding;" },
  { name: 'seeded-rand', sql: "DECLARE @s nvarchar(100)=CONVERT(nvarchar(100),RAND(42)); SELECT @s AS source, AI_GENERATE_EMBEDDINGS(@s USE MODEL m) AS embedding;" },
  { name: 'volatile-rand', volatileSource: true, sql: "DECLARE @s nvarchar(100)=CONVERT(nvarchar(100),RAND()); SELECT @s AS source, AI_GENERATE_EMBEDDINGS(@s USE MODEL m) AS embedding;" },
  { name: 'volatile-time', volatileSource: true, sql: "DECLARE @s nvarchar(100)=CONVERT(nvarchar(100),SYSDATETIME(),126); SELECT @s AS source, AI_GENERATE_EMBEDDINGS(@s USE MODEL m) AS embedding;" },
  { name: 'clock-after-http', response: { body: { data: [{ embedding: [1,2] }] }, delayMs: 400 }, sql: "DECLARE @before datetime2=SYSDATETIME(); SELECT AI_GENERATE_EMBEDDINGS(N'hello' USE MODEL m) AS embedding; SELECT CASE WHEN DATEDIFF(millisecond,@before,SYSDATETIME())>=300 THEN 1 ELSE 0 END AS advanced;" },
  { name: 'random-continuation', sql: "DECLARE @s nvarchar(100)=CONVERT(nvarchar(100),RAND(42)); SELECT @s AS source, AI_GENERATE_EMBEDDINGS(@s USE MODEL m) AS embedding; SELECT RAND() AS after_http; SELECT RAND() AS next_value;" },
  { name: 'two-rows', sql: "SELECT s, AI_GENERATE_EMBEDDINGS(s USE MODEL m) AS embedding FROM (VALUES(N'first'),(N'second')) AS v(s);" },
].map(c => ({ api: 'OpenAI', response: { body: { data: [{ embedding: [1,2] }] } }, ...c }))
