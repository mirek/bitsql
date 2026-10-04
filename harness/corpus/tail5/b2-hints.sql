-- Table hint shapes: INDEX hints on a view are ignored with INFO 4430 at
-- compile time (once per reference, index names unchecked); INDEX hints on
-- an INSERT/UPDATE/DELETE target are 1069 for the whole batch (allowed in
-- FROM); `t (a, b)` on a table or view is 207 per bare word + 215 (line 13
-- for a schema-qualified name); `t alias (NOLOCK, X)` is 1018 near X when X
-- is a hint word, else 102; `t alias (word)` is a hint (321 when unknown).
-- @step setup
CREATE TABLE hp (id int NOT NULL CONSTRAINT PK_hp PRIMARY KEY, v int); INSERT INTO hp VALUES (1,1),(2,2);
-- @step setup
CREATE VIEW hv AS SELECT id FROM hp
-- @step batch
SELECT 1 AS a; SELECT COUNT(*) AS n FROM hp (NOLOCK, READPAST)
-- @step batch
SELECT COUNT(*) AS n FROM hp (1)
-- @step batch
SELECT COUNT(*) AS n FROM hp (x, 1)
-- @step batch
SELECT COUNT(*) AS n FROM hp (NOLOCK, bogus)
-- @step batch
SELECT COUNT(*) AS n FROM hv (NOLOCK, READPAST)
-- @step batch
SELECT COUNT(*) AS n FROM hp h (NOLOCK, READPAST)
-- @step batch
SELECT COUNT(*) AS n FROM hp ([NOLOCK])
-- @step batch
SELECT COUNT(*) AS n FROM dbo.hp (v)
-- @step batch
SELECT 1 AS a; SELECT COUNT(*) AS n FROM hv WITH (INDEX(PK_hp))
-- @step batch
SELECT 1 AS a; SELECT COUNT(*) AS n FROM hv WITH (INDEX(nope))
-- @step batch
SELECT COUNT(*) AS n FROM hv WITH (INDEX(1)) JOIN hv AS w WITH (INDEX(0)) ON w.id = hv.id
-- @step batch
SELECT 1 AS a
SELECT COUNT(*) AS n FROM hv WITH (INDEX(1), NOLOCK)
-- @step batch
SELECT (SELECT COUNT(*) FROM hv WITH (INDEX = 1)) AS n
-- @step batch
SELECT COUNT(*) AS n FROM hv WITH (FORCESEEK)
-- @step batch
SELECT COUNT(*) AS n FROM hv WITH (FORCESCAN)
-- @step batch
BEGIN TRY SELECT COUNT(*) AS n FROM hv WITH (INDEX(1)) END TRY BEGIN CATCH END CATCH
-- @step batch
SELECT 1 AS a; UPDATE hp WITH (INDEX(1)) SET v = v WHERE id = 0
-- @step batch
SELECT 1 AS a; DELETE hp WITH (INDEX(PK_hp)) WHERE id = 0
-- @step batch
SELECT 1 AS a; INSERT INTO hp WITH (INDEX(1)) VALUES (5, 5)
-- @step batch
SELECT 1 AS a; UPDATE h SET v = v FROM hp h WITH (INDEX(1)) WHERE id = 0
-- @step batch
SELECT 1 AS a; DELETE hv WITH (INDEX(1)) WHERE id = 0
-- @step batch
SELECT COUNT(*) AS n FROM hp h (NOLOCK, bogus)
-- @step batch
SELECT COUNT(*) AS n FROM hp h (bogus)
-- @step batch
SELECT COUNT(*) AS n FROM hp h (NOLOCK, READPAST, ROWLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp h (NOLOCK READPAST)
