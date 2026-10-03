-- UPDATE/DELETE target resolution against FROM: an unaliased target name
-- binds to the one FROM occurrence of that table even when aliased; two
-- aliased occurrences are 8154; an unaliased occurrence wins. A target row
-- matched by several source rows is changed and output once.
-- @step setup
CREATE TABLE r(id INT NOT NULL PRIMARY KEY, n INT NULL);
-- @step setup
DELETE r; INSERT INTO r VALUES(10,1),(20,2),(30,3);
-- @step batch
UPDATE r SET n=t.n+10 OUTPUT deleted.id, inserted.n FROM r t JOIN (VALUES(10)) s(id) ON t.id=s.id
-- @step setup
DELETE r; INSERT INTO r VALUES(10,1),(20,2),(30,3);
-- @step batch
DELETE r OUTPUT deleted.id FROM r t WHERE t.id=20
-- @step setup
DELETE r; INSERT INTO r VALUES(10,1),(20,2),(30,3);
-- @step batch
UPDATE dbo.r SET n=0 OUTPUT deleted.id FROM dbo.r AS t WHERE t.id=30
-- @step setup
DELETE r; INSERT INTO r VALUES(10,1),(20,2),(30,3);
-- @step batch
UPDATE r SET n=0 OUTPUT deleted.id FROM r AS t, (VALUES(20)) s(id) WHERE t.id=s.id
-- @step batch
UPDATE r SET n=0 FROM r t JOIN r u ON t.id=u.id WHERE t.id=10
-- @step batch
DELETE r FROM r t JOIN r u ON t.id=u.id WHERE t.id=10
-- @step setup
DELETE r; INSERT INTO r VALUES(10,1),(20,2),(30,3);
-- @step batch
UPDATE r SET n=u.n+100 OUTPUT deleted.id, inserted.n FROM r JOIN r u ON r.id=u.id WHERE u.id=10
-- @step setup
DELETE r; INSERT INTO r VALUES(10,1),(20,2),(30,3);
-- @step batch
UPDATE r SET n=t.n+100 OUTPUT deleted.id, inserted.n FROM r t JOIN r ON r.id=t.id WHERE t.id=10
-- @step setup
DELETE r; INSERT INTO r VALUES(10,1),(20,2),(30,3);
-- @step batch
UPDATE t SET n=s.v OUTPUT deleted.id, inserted.n FROM r t JOIN (VALUES(10,5),(10,5),(20,7)) s(id,v) ON t.id=s.id
-- @step batch
DELETE t OUTPUT deleted.id FROM r t JOIN (VALUES(10),(10),(30)) s(id) ON t.id=s.id
-- @step batch
SELECT id, n FROM r ORDER BY id
