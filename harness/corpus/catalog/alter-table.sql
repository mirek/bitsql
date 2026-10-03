-- ALTER TABLE: ADD (NULL, DEFAULT, WITH VALUES, identity, computed),
-- ALTER COLUMN, DROP CONSTRAINT/COLUMN, CHECK/NOCHECK, completions (216).
-- @step setup
CREATE TABLE dbo.a (id int NOT NULL CONSTRAINT pk_a PRIMARY KEY, x int NULL, s nvarchar(10) NULL);
INSERT INTO dbo.a VALUES (1, NULL, N'hello'), (2, 2, N'x');
-- @step batch
ALTER TABLE dbo.a ADD y int NULL DEFAULT 7;
ALTER TABLE dbo.a ADD z int NULL CONSTRAINT df_a_z DEFAULT 8 WITH VALUES, w int NOT NULL CONSTRAINT df_a_w DEFAULT 9;
ALTER TABLE dbo.a ADD n int IDENTITY(10, 10) NOT NULL, d AS id * 100;
-- @step batch
SELECT id, x, s, y, z, w, n, d FROM dbo.a ORDER BY id;
INSERT INTO dbo.a (id) VALUES (3);
SELECT id, x, s, y, z, w, n, d FROM dbo.a ORDER BY id;
-- @step batch
ALTER TABLE dbo.a ALTER COLUMN s nvarchar(20) NOT NULL;
-- @step batch
UPDATE dbo.a SET s = N'' WHERE s IS NULL;
ALTER TABLE dbo.a ALTER COLUMN s nvarchar(20) NOT NULL;
ALTER TABLE dbo.a ALTER COLUMN x bigint;
SELECT column_id, name, system_type_id, max_length, is_nullable FROM sys.columns WHERE object_id = OBJECT_ID('dbo.a') ORDER BY column_id;
-- @step batch
ALTER TABLE dbo.a DROP CONSTRAINT df_a_w, COLUMN w;
ALTER TABLE dbo.a DROP COLUMN d, n;
SELECT name, column_id FROM sys.columns WHERE object_id = OBJECT_ID('dbo.a') ORDER BY column_id;
SELECT max_column_id_used FROM sys.tables WHERE name = 'a';
SELECT * FROM dbo.a ORDER BY id;
-- @step batch
ALTER TABLE dbo.a WITH NOCHECK ADD CONSTRAINT ck_a_x CHECK (x > 5);
SELECT name, is_disabled, is_not_trusted FROM sys.check_constraints;
ALTER TABLE dbo.a NOCHECK CONSTRAINT ck_a_x;
SELECT name, is_disabled, is_not_trusted FROM sys.check_constraints;
INSERT INTO dbo.a (id, x, s) VALUES (4, 1, N'q');
ALTER TABLE dbo.a CHECK CONSTRAINT ALL;
SELECT name, is_disabled, is_not_trusted FROM sys.check_constraints;
-- @step batch
ALTER TABLE dbo.a WITH CHECK CHECK CONSTRAINT ck_a_x;
-- @step batch
ALTER TABLE dbo.a ADD CONSTRAINT ck_a_id CHECK (id < 3);
-- @step batch
ALTER TABLE dbo.a ADD CONSTRAINT uq_a_y UNIQUE (y);
-- @step batch
ALTER TABLE dbo.a ADD q int NOT NULL;
-- @step batch
ALTER TABLE dbo.a ALTER COLUMN s int;
-- @step batch
ALTER TABLE dbo.a ALTER COLUMN s nvarchar(3);
-- @step batch
ALTER TABLE dbo.a ALTER COLUMN x int NOT NULL;
-- @step batch
SELECT id, x, s, y, z FROM dbo.a ORDER BY id;
