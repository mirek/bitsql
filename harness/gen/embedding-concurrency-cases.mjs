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
