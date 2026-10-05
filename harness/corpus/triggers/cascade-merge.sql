-- MERGE whose cascades update and delete rows of one child table: the
-- child's UPDATE triggers fire, then its DELETE triggers, each with
-- @@ROWCOUNT = all cascaded rows of that table; a grandchild changed by
-- both ON UPDATE CASCADE and ON DELETE SET NULL fires once.
-- @step setup
CREATE TABLE log1 (seq int IDENTITY, what varchar(300));
CREATE TABLE p (id int PRIMARY KEY, v int);
CREATE TABLE c (id int PRIMARY KEY, pid int REFERENCES p(id) ON DELETE CASCADE ON UPDATE CASCADE, v int);
CREATE TABLE g (id int PRIMARY KEY, cpid int, cid int, CONSTRAINT fkg FOREIGN KEY (cid) REFERENCES c(id) ON UPDATE CASCADE ON DELETE SET NULL);
INSERT p VALUES (1, 10), (2, 20), (3, 30);
INSERT c VALUES (11, 1, 0), (21, 2, 0), (31, 3, 0);
INSERT g VALUES (111, 1, 11), (211, 2, 21);
-- @step setup
CREATE TRIGGER tp ON p AFTER INSERT, DELETE, UPDATE AS BEGIN DECLARE @rc int = @@ROWCOUNT; SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('p rc=', @rc, ' del=', (SELECT STRING_AGG(id, ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT STRING_AGG(id, ',') WITHIN GROUP (ORDER BY id) FROM inserted)); END;
-- @step setup
CREATE TRIGGER tcd ON c AFTER DELETE AS BEGIN DECLARE @rc int = @@ROWCOUNT; SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('c del rc=', @rc, ' del=', (SELECT STRING_AGG(CONCAT(id, ':', pid), ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT COUNT(*) FROM inserted)); END;
-- @step setup
CREATE TRIGGER tcu ON c AFTER UPDATE AS BEGIN DECLARE @rc int = @@ROWCOUNT; SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('c upd rc=', @rc, ' del=', (SELECT STRING_AGG(CONCAT(id, ':', pid), ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT STRING_AGG(CONCAT(id, ':', pid), ',') WITHIN GROUP (ORDER BY id) FROM inserted)); END;
-- @step setup
CREATE TRIGGER tg ON g AFTER UPDATE, DELETE AS BEGIN DECLARE @rc int = @@ROWCOUNT; SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('g rc=', @rc, ' del=', (SELECT STRING_AGG(CONCAT(id, ':', cid), ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT STRING_AGG(CONCAT(id, ':', ISNULL(cid, -1)), ',') WITHIN GROUP (ORDER BY id) FROM inserted), ' u=', IIF(UPDATE(cid), 1, 0), IIF(UPDATE(cpid), 1, 0)); END;
-- @step batch
MERGE p AS t USING (VALUES (1, 100), (2, NULL), (4, 4)) AS s(id, nid) ON t.id = s.id
WHEN MATCHED AND s.nid IS NULL THEN DELETE
WHEN MATCHED THEN UPDATE SET id = s.nid
WHEN NOT MATCHED THEN INSERT VALUES (s.id, 0);
SELECT what FROM log1 ORDER BY seq;
SELECT id, pid FROM c ORDER BY id;
SELECT id, cid FROM g ORDER BY id;
-- @step setup
CREATE TABLE log2 (seq int IDENTITY, what varchar(300));
CREATE TABLE p2 (id int PRIMARY KEY);
CREATE TABLE c2 (pid int PRIMARY KEY REFERENCES p2(id) ON DELETE CASCADE ON UPDATE CASCADE, w int);
CREATE TABLE g2 (id int PRIMARY KEY, cid int REFERENCES c2(pid) ON UPDATE CASCADE ON DELETE SET NULL);
INSERT p2 VALUES (1), (2), (3);
INSERT c2 VALUES (1, 0), (2, 0), (3, 0);
INSERT g2 VALUES (1, 1), (2, 2), (3, 3);
-- @step setup
CREATE TRIGGER tg2 ON g2 AFTER UPDATE, DELETE AS BEGIN DECLARE @rc int = @@ROWCOUNT; SET NOCOUNT ON;
  INSERT log2 SELECT CONCAT('g2 rc=', @rc, ' del=', (SELECT STRING_AGG(CONCAT(id, ':', cid), ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT STRING_AGG(CONCAT(id, ':', ISNULL(cid, -1)), ',') WITHIN GROUP (ORDER BY id) FROM inserted)); END;
-- @step batch
MERGE p2 AS t USING (VALUES (1, 100), (2, NULL)) AS s(id, nid) ON t.id = s.id
WHEN MATCHED AND s.nid IS NULL THEN DELETE
WHEN MATCHED THEN UPDATE SET id = s.nid;
SELECT what FROM log2 ORDER BY seq;
SELECT id, cid FROM g2 ORDER BY id;
-- @step batch
DELETE log2;
UPDATE p2 SET id = id + 10 WHERE id IN (3);
SELECT what FROM log2 ORDER BY seq;
