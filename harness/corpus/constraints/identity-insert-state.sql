-- IDENTITY_INSERT: result metadata of the identity column while ON, the
-- 8101 / 545 / 339 / 264 errors, the identity value after a failed row,
-- and XACT_STATE() in autocommit statements that read data.
-- @step setup
CREATE TABLE t (id int IDENTITY(1, 1) NOT NULL CONSTRAINT pk_t PRIMARY KEY, v int NOT NULL CONSTRAINT ck_v CHECK (v > 0));
INSERT t (v) VALUES (1);
-- @step batch
SELECT id, v FROM t;
SET IDENTITY_INSERT t ON;
SELECT id, v FROM t;
-- @step batch
INSERT t (id, v) VALUES (50, -1);
-- @step batch
SELECT IDENT_CURRENT('t') AS cur;
-- @step batch
INSERT t VALUES (60, 1);
-- @step batch
INSERT t (v, id) VALUES (2, NULL);
-- @step batch
INSERT t (v) SELECT 3;
-- @step batch
INSERT t (id, v, id) VALUES (70, 1, 71);
-- @step batch
INSERT t (id, v) OUTPUT inserted.id VALUES (80, 4);
SET IDENTITY_INSERT t OFF;
INSERT t (v) OUTPUT inserted.id VALUES (5);
-- @step batch
SELECT XACT_STATE() AS bare, @@TRANCOUNT AS tc;
SELECT XACT_STATE() AS with_from, (SELECT COUNT(*) FROM t) AS n;
SELECT XACT_STATE() AS with_object_id, OBJECT_ID('t') - OBJECT_ID('t') AS z;
SELECT 'FROM' AS literal, XACT_STATE() AS literal_from;
