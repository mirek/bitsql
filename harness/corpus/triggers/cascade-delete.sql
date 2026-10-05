-- AFTER triggers on tables changed by cascading referential actions
-- (compat report 0.1.3 #7). Cascades run first, then the child tables'
-- triggers in reverse depth-first order (children by foreign key creation
-- order), then the statement's own triggers. Each child trigger sees the
-- cascaded rows, @@ROWCOUNT = its table's cascaded rows, nest level 1.
-- @step setup
CREATE TABLE parent (id int PRIMARY KEY);
CREATE TABLE items (id int PRIMARY KEY, parent_id int REFERENCES parent(id) ON DELETE CASCADE);
CREATE TABLE audit (value int);
INSERT parent VALUES (1);
INSERT items VALUES (1, 1);
-- @step setup
CREATE TRIGGER foo_trigger ON items AFTER DELETE AS BEGIN
  SET NOCOUNT ON;
  INSERT audit SELECT COUNT(*) FROM deleted;
END;
-- @step batch
DELETE parent;
SELECT COUNT(*) AS remaining FROM items;
SELECT value FROM audit;
-- @step setup
CREATE TABLE log1 (seq int IDENTITY, what varchar(300));
CREATE TABLE p (id int PRIMARY KEY, v int);
CREATE TABLE c (id int PRIMARY KEY, pid int REFERENCES p(id) ON DELETE CASCADE ON UPDATE CASCADE, v int);
CREATE TABLE g (id int PRIMARY KEY, cid int REFERENCES c(id) ON DELETE CASCADE, v int);
CREATE TABLE n (id int PRIMARY KEY, pid int REFERENCES p(id) ON DELETE SET NULL ON UPDATE SET NULL);
INSERT p VALUES (1, 10), (2, 20), (3, 30);
INSERT c VALUES (11, 1, 0), (12, 1, 0), (21, 2, 0), (31, 3, 0);
INSERT g VALUES (111, 11, 0), (112, 11, 0), (211, 21, 0);
INSERT n VALUES (1, 1), (2, 2), (3, NULL);
-- @step setup
CREATE TRIGGER tp ON p AFTER DELETE, UPDATE AS BEGIN
  DECLARE @rc int = @@ROWCOUNT;
  SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('p rc=', @rc, ' nest=', TRIGGER_NESTLEVEL(), ' del=', (SELECT COUNT(*) FROM deleted), ' ins=', (SELECT COUNT(*) FROM inserted), ' cnow=', (SELECT COUNT(*) FROM c), ' gnow=', (SELECT COUNT(*) FROM g));
END;
-- @step setup
CREATE TRIGGER tc ON c AFTER DELETE, UPDATE AS BEGIN
  DECLARE @rc int = @@ROWCOUNT;
  SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('c rc=', @rc, ' nest=', TRIGGER_NESTLEVEL(), ' del=', (SELECT STRING_AGG(CONCAT(id, ':', pid), ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT STRING_AGG(CONCAT(id, ':', pid), ',') WITHIN GROUP (ORDER BY id) FROM inserted), ' upd_pid=', IIF(UPDATE(pid), 1, 0), ' upd_v=', IIF(UPDATE(v), 1, 0), ' cu=', CONVERT(varchar(20), COLUMNS_UPDATED(), 1), ' pnow=', (SELECT COUNT(*) FROM p), ' gnow=', (SELECT COUNT(*) FROM g));
END;
-- @step setup
CREATE TRIGGER tg ON g AFTER DELETE AS BEGIN
  DECLARE @rc int = @@ROWCOUNT;
  SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('g rc=', @rc, ' nest=', TRIGGER_NESTLEVEL(), ' del=', (SELECT STRING_AGG(id, ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT COUNT(*) FROM inserted));
END;
-- @step setup
CREATE TRIGGER tn ON n AFTER UPDATE AS BEGIN
  DECLARE @rc int = @@ROWCOUNT;
  SET NOCOUNT ON;
  INSERT log1 SELECT CONCAT('n rc=', @rc, ' nest=', TRIGGER_NESTLEVEL(), ' del=', (SELECT STRING_AGG(CONCAT(id, ':', pid), ',') WITHIN GROUP (ORDER BY id) FROM deleted), ' ins=', (SELECT STRING_AGG(CONCAT(id, ':', ISNULL(pid, -1)), ',') WITHIN GROUP (ORDER BY id) FROM inserted), ' upd_pid=', IIF(UPDATE(pid), 1, 0));
END;
-- @step batch
DELETE p WHERE id IN (1, 2);
SELECT @@ROWCOUNT AS rc;
SELECT seq, what FROM log1 ORDER BY seq;
SELECT id FROM c ORDER BY id;
SELECT id, pid FROM n ORDER BY id;
-- @step batch
DELETE log1;
DELETE p WHERE id = 99;
SELECT what FROM log1 ORDER BY seq;
