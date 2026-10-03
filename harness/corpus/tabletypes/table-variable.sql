-- DECLARE @t <table type>: defaults, IDENTITY, PK and CHECK enforcement,
-- result metadata, schema-less and AS forms, table variable semantics.
-- @step setup
CREATE TYPE dbo.IdList AS TABLE (id int NOT NULL PRIMARY KEY, name nvarchar(20) NULL DEFAULT N'x', n int IDENTITY(10, 5), CHECK (id > 0));
-- @step batch
DECLARE @t dbo.IdList;
INSERT INTO @t (id) VALUES (2), (1);
INSERT INTO @t (id, name) VALUES (3, N'c');
SELECT * FROM @t ORDER BY id;
UPDATE @t SET name = N'y' WHERE id = 1;
DELETE FROM @t WHERE id = 2;
SELECT id, name, n FROM @t ORDER BY id;
-- @step batch
DECLARE @t AS IdList;
SELECT * FROM @t;
SELECT COUNT(*) AS c FROM @t;
-- @step batch
DECLARE @t dbo.IdList;
BEGIN TRY
  INSERT INTO @t (id) VALUES (1), (1);
END TRY
BEGIN CATCH
  SELECT ERROR_NUMBER() AS num, ERROR_SEVERITY() AS sev;
END CATCH;
BEGIN TRY
  INSERT INTO @t (id) VALUES (0);
END TRY
BEGIN CATCH
  SELECT ERROR_NUMBER() AS num, ERROR_SEVERITY() AS sev;
END CATCH;
SELECT COUNT(*) AS c FROM @t;
-- @step batch
DECLARE @t dbo.IdList;
BEGIN TRAN;
INSERT INTO @t (id) VALUES (7);
ROLLBACK;
SELECT id, name, n FROM @t;
-- @step batch
DECLARE @a dbo.IdList, @b int = 5;
INSERT INTO @a (id) VALUES (@b);
SELECT id FROM @a;
-- @step batch
DECLARE @t dbo.IdList;
DECLARE @t int;
-- @step batch
DECLARE @t dbo.IdList;
SELECT @t;
-- @step batch
DECLARE @t dbo.IdList;
INSERT INTO @t (id) SELECT 4;
SELECT id FROM @t AS x WHERE x.id = 4;
