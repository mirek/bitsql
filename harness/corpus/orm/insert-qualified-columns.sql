-- Prisma's createMany names INSERT columns with their schema and table:
-- `INSERT INTO [dbo].[users] ([dbo].[users].[email], ...)`. SQL Server
-- accepts up to four-part column names there and ignores the qualifiers,
-- even ones naming another table.
-- @step setup
CREATE TABLE t (id int NOT NULL, d float NULL, r real NULL);
-- @step batch
INSERT INTO [dbo].[t] ([dbo].[t].[id], [t].[d], dbo.t.r) VALUES (1, 2.5, 3), (2, NULL, NULL);
SELECT id, d, r FROM t ORDER BY id;
-- @step batch
INSERT INTO t (x.id) VALUES (3);
INSERT INTO t (other.dbo.t.id) VALUES (4);
INSERT INTO t (zz.t.id, t.d) SELECT 5, 1.5;
SELECT id, d FROM t ORDER BY id;
