-- Selecting from views: column names/types/flags, nested views, declared
-- column lists, ALTER VIEW changing the shape, joins with tables.
-- @step setup
CREATE TABLE dbo.p (id int NOT NULL CONSTRAINT pk_p PRIMARY KEY, a int NULL, s nvarchar(10) NULL);
INSERT INTO dbo.p VALUES (1, 10, N'x'), (2, NULL, N'y');
-- @step setup
CREATE VIEW dbo.v1 AS SELECT id, a, a + 1 AS a1 FROM dbo.p WHERE id > 0
-- @step setup
CREATE VIEW dbo.v2 (k, label) AS SELECT id, s FROM dbo.p
-- @step setup
CREATE VIEW dbo.v3 AS SELECT v1.id, v2.label FROM dbo.v1 JOIN dbo.v2 ON v2.k = v1.id
-- @step batch
SELECT * FROM dbo.v1 ORDER BY id;
SELECT k, label FROM v2 WHERE k = 2;
SELECT x.id, x.label, p.a FROM dbo.v3 AS x JOIN dbo.p AS p ON p.id = x.id ORDER BY x.id;
SELECT name, column_id, system_type_id, max_length, is_nullable FROM sys.columns WHERE object_id = OBJECT_ID('dbo.v2') ORDER BY column_id;
-- @step batch
ALTER VIEW dbo.v1 AS SELECT id, s FROM dbo.p
-- @step batch
SELECT * FROM dbo.v1 ORDER BY id;
