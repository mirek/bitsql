-- MERGE cascading into a child's unique key: SQL Server splits the
-- cascaded update, so the child's UPDATE trigger sees empty inserted /
-- deleted and its DELETE trigger also sees the updated rows. bitsql
-- raises 50100 for triggers on such a child (not in the allowlist).
-- @step setup
CREATE TABLE log1 (seq int IDENTITY, what varchar(300));
CREATE TABLE p (id int PRIMARY KEY);
CREATE TABLE c (pid int PRIMARY KEY REFERENCES p(id) ON DELETE CASCADE ON UPDATE CASCADE);
INSERT p VALUES (1), (2), (3);
INSERT c VALUES (1), (2), (3);
-- @step setup
CREATE TRIGGER tcd ON c AFTER DELETE AS BEGIN DECLARE @rc int = @@ROWCOUNT; SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('c del rc=', @rc, ' del=', (SELECT STRING_AGG(pid, ',') WITHIN GROUP (ORDER BY pid) FROM deleted)); END;
-- @step setup
CREATE TRIGGER tcu ON c AFTER UPDATE AS BEGIN DECLARE @rc int = @@ROWCOUNT; SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('c upd rc=', @rc, ' del=', (SELECT STRING_AGG(pid, ',') WITHIN GROUP (ORDER BY pid) FROM deleted), ' ins=', (SELECT STRING_AGG(pid, ',') WITHIN GROUP (ORDER BY pid) FROM inserted)); END;
-- @step batch
MERGE p AS t USING (VALUES (1, 100), (2, NULL)) AS s(id, nid) ON t.id = s.id
WHEN MATCHED AND s.nid IS NULL THEN DELETE
WHEN MATCHED THEN UPDATE SET id = s.nid;
SELECT what FROM log1 ORDER BY seq;
-- @step batch
DELETE log1;
MERGE p AS t USING (VALUES (100, 200)) AS s(id, nid) ON t.id = s.id
WHEN MATCHED THEN UPDATE SET id = s.nid;
SELECT what FROM log1 ORDER BY seq;
