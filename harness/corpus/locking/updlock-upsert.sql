-- Upsert pattern: SELECT ... WITH (UPDLOCK, HOLDLOCK) serializes two sessions
-- on the same missing key; the second sees the first's insert.
-- @step setup
CREATE TABLE u (id int PRIMARY KEY, n int);
-- @step batch
BEGIN TRAN;
IF NOT EXISTS (SELECT 1 FROM u WITH (UPDLOCK, HOLDLOCK) WHERE id = 7)
  INSERT u VALUES (7, 1);
-- @step batch conn=2 async
BEGIN TRAN;
IF NOT EXISTS (SELECT 1 FROM u WITH (UPDLOCK, HOLDLOCK) WHERE id = 7)
  INSERT u VALUES (7, 1);
ELSE
  UPDATE u SET n = n + 1 WHERE id = 7;
COMMIT;
-- @step batch
COMMIT;
-- @step await conn=2
-- @step batch
SELECT id, n FROM u;
