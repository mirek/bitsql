-- An error or ROLLBACK in a trigger fired by a cascading referential action
-- undoes the whole statement (parent, cascaded rows, trigger writes).
-- @step setup
CREATE TABLE log1 (seq int IDENTITY, what varchar(300));
CREATE TABLE p (id int PRIMARY KEY);
CREATE TABLE a (id int PRIMARY KEY, pid int REFERENCES p(id) ON DELETE CASCADE);
CREATE TABLE z (id int PRIMARY KEY, pid int REFERENCES p(id) ON DELETE SET NULL);
INSERT p VALUES (1), (2);
INSERT a VALUES (1, 1), (2, 2);
INSERT z VALUES (1, 1), (2, 2);
-- @step setup
CREATE TRIGGER ta ON a AFTER DELETE AS BEGIN SET NOCOUNT ON; INSERT log1 VALUES ('a'); END;
-- @step setup
CREATE TRIGGER tz_fail ON z AFTER UPDATE AS BEGIN SET NOCOUNT ON; INSERT log1 VALUES ('z_fail'); THROW 50001, 'nope', 1; END;
-- @step batch
DELETE p WHERE id = 2;
SELECT 'not reached' AS x;
-- @step batch
SELECT id FROM p ORDER BY id;
SELECT id FROM a ORDER BY id;
SELECT id, pid FROM z ORDER BY id;
SELECT what FROM log1;
SELECT @@TRANCOUNT AS tc;
-- @step batch
BEGIN TRY DELETE p WHERE id = 2; END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, XACT_STATE() AS xs, @@TRANCOUNT AS tc; END CATCH;
SELECT COUNT(*) AS pc FROM p;
-- @step batch
BEGIN TRAN;
BEGIN TRY DELETE p WHERE id = 2; END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, XACT_STATE() AS xs, @@TRANCOUNT AS tc; END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT COUNT(*) AS pc FROM p;
-- @step setup
DROP TRIGGER tz_fail;
-- @step setup
CREATE TRIGGER tz_rb ON z AFTER UPDATE AS BEGIN ROLLBACK; END;
-- @step batch
DELETE p WHERE id = 2;
SELECT 'not reached' AS x;
-- @step batch
SELECT COUNT(*) AS pc FROM p;
SELECT COUNT(*) AS ac FROM a;
SELECT @@TRANCOUNT AS tc;
SELECT what FROM log1;
