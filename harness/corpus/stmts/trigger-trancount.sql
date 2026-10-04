-- @@TRANCOUNT read inside a data-modifying statement is one more than the
-- open transactions, counting autocommit as one (INSERT/UPDATE/DELETE/MERGE,
-- SELECT INTO, OUTPUT); a plain SELECT or assignment reads the real count.
-- Inside an AFTER trigger: @@ROWCOUNT on entry is the firing statement's
-- count, @@TRANCOUNT is 1 (2 inside the trigger's own DML).
-- @step setup
CREATE TABLE x (k int, a int, b int);
CREATE TABLE y (id int);
CREATE TABLE ylog (rc int, tc int, tc2 int, xs int);
-- @step setup
CREATE TRIGGER y_t ON y AFTER INSERT AS
DECLARE @rc int = @@ROWCOUNT, @tc int = @@TRANCOUNT;
INSERT ylog VALUES (@rc, @tc, @@TRANCOUNT, XACT_STATE());
-- @step batch
INSERT x (k, a) SELECT 1, @@TRANCOUNT;
INSERT x (k, a) VALUES (2, @@TRANCOUNT);
SELECT @@TRANCOUNT AS plain, (SELECT COUNT(*) FROM x) AS n;
UPDATE x SET b = @@TRANCOUNT;
SELECT k, a, b FROM x ORDER BY k;
-- @step batch
BEGIN TRAN;
INSERT x (k, a) SELECT 3, @@TRANCOUNT;
BEGIN TRAN;
INSERT x (k, a) VALUES (4, @@TRANCOUNT);
COMMIT;
COMMIT;
SELECT k, a FROM x WHERE k >= 3 ORDER BY k;
-- @step batch
DELETE x WHERE @@TRANCOUNT = 2;
SELECT @@ROWCOUNT AS deleted;
-- @step batch
INSERT x (k, a) VALUES (5, 0);
MERGE x USING (VALUES (5)) s(k) ON x.k = s.k WHEN MATCHED THEN UPDATE SET a = @@TRANCOUNT;
SELECT k, a FROM x;
-- @step batch
SELECT @@TRANCOUNT AS t INTO #z;
SELECT t FROM #z;
DECLARE @v int;
SELECT @v = @@TRANCOUNT FROM x;
SELECT @v AS v;
-- @step batch
INSERT x (k, a) OUTPUT @@TRANCOUNT AS o VALUES (6, 0);
-- @step batch
INSERT y VALUES (1), (2);
BEGIN TRAN;
INSERT y VALUES (3);
COMMIT;
SELECT rc, tc, tc2, xs FROM ylog ORDER BY rc DESC;
