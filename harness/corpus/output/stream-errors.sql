-- OUTPUT without INTO sends its COLMETADATA before the statement runs; a
-- run-time error then ends the stream. Rows produced before the failing
-- row stay sent. Also: 3621 after the error, DONE with the DML CurCmd.
-- @step setup
CREATE TABLE r(id INT NOT NULL CONSTRAINT pk_r PRIMARY KEY, n INT NULL, c INT NULL CONSTRAINT ck_r_c CHECK (c IS NULL OR c < 100));
INSERT INTO r VALUES(10,1,NULL),(20,0,NULL),(30,3,NULL);
-- @step batch
UPDATE r SET n=10/n OUTPUT inserted.id, inserted.n
-- @step batch
UPDATE r SET n=n OUTPUT inserted.id, 10/inserted.n AS q
-- @step batch
DELETE r OUTPUT deleted.id WHERE 10/n > 0
-- @step batch
DELETE r OUTPUT deleted.id, 10/deleted.n AS q
-- @step batch
INSERT INTO r(id,n) OUTPUT inserted.id SELECT id+100, 10/n FROM r
-- @step batch
INSERT INTO r(id,n) OUTPUT inserted.id VALUES(40,1),(50,1/0),(60,1)
-- @step batch
UPDATE r SET c=id*5 OUTPUT inserted.id, inserted.c
-- @step batch
UPDATE r SET id=10 OUTPUT deleted.id, inserted.id
-- @step batch
UPDATE r SET id=30 OUTPUT deleted.id, inserted.id
-- @step batch
UPDATE r SET n=n OUTPUT inserted.id WHERE 10/n > 0
-- @step batch
INSERT INTO r(id,n,c) OUTPUT inserted.id VALUES(40,1,50),(50,1,150),(60,1,1)
-- @step batch
INSERT INTO r(id,n) OUTPUT inserted.id, 10/inserted.n AS q VALUES(40,1),(50,0),(60,1)
-- @step batch
INSERT INTO r(id,n) OUTPUT inserted.id VALUES(40,1),(10,1),(60,1)
-- @step batch
INSERT INTO r(id,n) OUTPUT inserted.id VALUES(40,1),(NULL,1),(60,1)
-- @step batch
MERGE r USING (VALUES(10),(20),(30)) s(id) ON r.id=s.id WHEN MATCHED THEN UPDATE SET n=10/r.n OUTPUT $action, inserted.id;
-- @step batch
UPDATE r SET n=10/n OUTPUT inserted.id; SELECT 1 AS after_error
-- @step batch
BEGIN TRY UPDATE r SET n=10/n OUTPUT inserted.id, inserted.n; END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS e, @@ROWCOUNT AS rc; END CATCH
-- @step batch
SELECT id, n, c FROM r ORDER BY id
-- @step batch
UPDATE r SET id=id+10 OUTPUT deleted.id, inserted.id;
SELECT id, n, c FROM r ORDER BY id
