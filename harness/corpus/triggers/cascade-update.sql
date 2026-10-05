-- AFTER UPDATE triggers on child tables changed by ON UPDATE CASCADE,
-- ON UPDATE / ON DELETE SET NULL and SET DEFAULT: UPDATE() and
-- COLUMNS_UPDATED() name only the foreign key columns.
-- @step setup
CREATE TABLE log1 (seq int IDENTITY, what varchar(300));
CREATE TABLE p (id int PRIMARY KEY, v int);
CREATE TABLE c (id int PRIMARY KEY, pid int REFERENCES p(id) ON DELETE CASCADE ON UPDATE CASCADE, v int);
CREATE TABLE g (id int PRIMARY KEY, w int, cid int, CONSTRAINT fkg FOREIGN KEY (cid) REFERENCES c(id) ON UPDATE CASCADE ON DELETE SET NULL);
CREATE TABLE n (id int PRIMARY KEY, pid int REFERENCES p(id) ON DELETE SET NULL ON UPDATE SET NULL);
CREATE TABLE sd (id int PRIMARY KEY, pid int DEFAULT 9 REFERENCES p(id) ON DELETE SET DEFAULT ON UPDATE SET DEFAULT);
INSERT p VALUES (1, 10), (2, 20), (3, 30), (9, 90);
INSERT c VALUES (11, 1, 0), (12, 1, 0), (21, 2, 0), (31, 3, 0);
INSERT g VALUES (111, 0, 11), (211, 0, 21);
INSERT n VALUES (1, 1), (2, 2), (3, NULL);
INSERT sd VALUES (1, 1), (2, 2);
-- @step setup
CREATE TRIGGER tp ON p AFTER UPDATE AS BEGIN
  DECLARE @rc int = @@ROWCOUNT;
  SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('p rc=', @rc, ' del=', (SELECT STRING_AGG(id, ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT STRING_AGG(id, ',') WITHIN GROUP (ORDER BY id) FROM inserted));
END;
-- @step setup
CREATE TRIGGER tc ON c AFTER UPDATE AS BEGIN
  DECLARE @rc int = @@ROWCOUNT;
  SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('c rc=', @rc, ' del=', (SELECT STRING_AGG(CONCAT(id, ':', pid), ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT STRING_AGG(CONCAT(id, ':', pid), ',') WITHIN GROUP (ORDER BY id) FROM inserted), ' u=', IIF(UPDATE(id), 1, 0), IIF(UPDATE(pid), 1, 0), IIF(UPDATE(v), 1, 0), ' cu=', CONVERT(varchar(20), COLUMNS_UPDATED(), 1));
END;
-- @step setup
CREATE TRIGGER tg ON g AFTER UPDATE, DELETE AS BEGIN
  DECLARE @rc int = @@ROWCOUNT;
  SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('g rc=', @rc, ' del=', (SELECT STRING_AGG(CONCAT(id, ':', cid), ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT STRING_AGG(CONCAT(id, ':', ISNULL(cid, -1)), ',') WITHIN GROUP (ORDER BY id) FROM inserted), ' u=', IIF(UPDATE(w), 1, 0), IIF(UPDATE(cid), 1, 0), ' cu=', CONVERT(varchar(20), COLUMNS_UPDATED(), 1));
END;
-- @step setup
CREATE TRIGGER tn ON n AFTER UPDATE AS BEGIN
  DECLARE @rc int = @@ROWCOUNT;
  SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('n rc=', @rc, ' del=', (SELECT STRING_AGG(CONCAT(id, ':', pid), ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT STRING_AGG(CONCAT(id, ':', ISNULL(pid, -1)), ',') WITHIN GROUP (ORDER BY id) FROM inserted), ' u=', IIF(UPDATE(pid), 1, 0));
END;
-- @step setup
CREATE TRIGGER tsd ON sd AFTER UPDATE AS BEGIN
  DECLARE @rc int = @@ROWCOUNT;
  SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('sd rc=', @rc, ' del=', (SELECT STRING_AGG(CONCAT(id, ':', pid), ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT STRING_AGG(CONCAT(id, ':', pid), ',') WITHIN GROUP (ORDER BY id) FROM inserted));
END;
-- @step batch
UPDATE p SET id = id + 100 WHERE id IN (1, 2);
SELECT @@ROWCOUNT AS rc;
SELECT what FROM log1 ORDER BY seq;
SELECT id, pid FROM c ORDER BY id;
SELECT id, pid FROM n ORDER BY id;
SELECT id, pid FROM sd ORDER BY id;
-- @step batch
DELETE log1;
UPDATE p SET v = 1;
SELECT what FROM log1 ORDER BY seq;
-- @step batch
DELETE log1;
UPDATE c SET id = id + 1;
SELECT what FROM log1 ORDER BY seq;
-- @step batch
DELETE log1;
DELETE c WHERE id = 12;
SELECT what FROM log1 ORDER BY seq;
SELECT id, cid FROM g ORDER BY id;
-- @step batch
DELETE log1;
DISABLE TRIGGER tc ON c;
UPDATE p SET id = 5 WHERE id = 3;
SELECT what FROM log1 ORDER BY seq;
ENABLE TRIGGER tc ON c;
-- @step batch
DELETE log1;
BEGIN TRAN;
UPDATE p SET id = 6 WHERE id = 5;
SELECT what FROM log1 ORDER BY seq;
ROLLBACK;
SELECT id, pid FROM c ORDER BY id;
SELECT COUNT(*) AS logged FROM log1;
