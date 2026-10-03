-- Name resolution in OUTPUT of UPDATE/DELETE ... FROM: the target's alias
-- or name is not visible (4104, 107 for t.*), other FROM sources are, but
-- only qualified (unqualified names are 207); x.* of a source expands;
-- inserted/deleted always mean the pseudo-tables. A qualifier naming a
-- table without that column is 207, also in subqueries (inner aliases
-- shadow outer ones).
-- @step setup
CREATE TABLE r(id INT NOT NULL PRIMARY KEY, n INT NULL);
INSERT INTO r VALUES(10,1),(20,2);
CREATE TABLE lk(id INT NOT NULL, n INT NOT NULL);
INSERT INTO lk VALUES(10,50),(20,60);
-- @step batch
SELECT s.missing FROM (VALUES(1)) s(a)
-- @step batch
SELECT (SELECT s.extra FROM lk s WHERE s.id=10) AS x FROM (VALUES(1,2)) s(a,extra)
-- @step batch
SELECT (SELECT s.a FROM lk WHERE lk.id=10) AS x FROM (VALUES(1,2)) s(a,extra)
-- @step batch
UPDATE r SET n=s.n OUTPUT r.id FROM (VALUES(10,7)) s(id,n) WHERE r.id=s.id
-- @step batch
UPDATE r SET n=5 OUTPUT r.id WHERE id=10
-- @step batch
DELETE t OUTPUT t.id FROM r t WHERE t.id=10
-- @step batch
DELETE t OUTPUT s.extra, extra, deleted.id FROM r t JOIN (VALUES(20,9)) s(id,extra) ON t.id=s.id
-- @step batch
UPDATE t SET n=7 OUTPUT n FROM r t JOIN (VALUES(10,9)) s(id,extra) ON t.id=s.id
-- @step batch
UPDATE t SET n=7 OUTPUT s.missing FROM r t JOIN (VALUES(10,9)) s(id,extra) ON t.id=s.id
-- @step batch
UPDATE t SET n=7 OUTPUT s.*, deleted.* FROM r t JOIN lk s ON t.id=s.id
-- @step batch
UPDATE t SET n=8 OUTPUT inserted.n, deleted.n, inserted.id FROM r t JOIN (VALUES(10,70)) inserted(id,n) ON t.id=inserted.id
-- @step batch
DELETE t OUTPUT deleted.n, s.* FROM r t JOIN (VALUES(10,70)) deleted(id,n) ON t.id=deleted.id CROSS JOIN (VALUES(1)) s(k)
-- @step batch
UPDATE r SET n=7 OUTPUT x.* WHERE id=10
-- @step batch
UPDATE r SET n=7 OUTPUT r.* WHERE id=10
-- @step batch
UPDATE t SET n=7 OUTPUT t.* FROM r t WHERE id=10
-- @step batch
INSERT INTO r(id,n) OUTPUT deleted.id VALUES(30,3)
-- @step batch
SELECT id, n FROM r ORDER BY id
