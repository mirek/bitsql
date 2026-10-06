-- Observed plan-dependent inserted row order; not an identity ordering contract.
-- @step setup
CREATE TABLE dbo.foo (owner int NOT NULL, name nvarchar(20) NOT NULL, PRIMARY KEY(owner,name));
CREATE TABLE dbo.bar (id bigint IDENTITY, name nvarchar(20));
-- @step setup
CREATE TRIGGER dbo.foo_ai ON dbo.foo AFTER INSERT AS INSERT dbo.bar(name) SELECT name FROM inserted;
-- @step batch
DELETE dbo.foo; TRUNCATE TABLE dbo.bar;
MERGE dbo.foo WITH (SERIALIZABLE) AS Target
USING (VALUES (N'b'),(N'a')) AS Source(id)
ON (Target.owner = 1 AND Target.name = Source.id)
WHEN NOT MATCHED BY TARGET THEN INSERT (owner,name) VALUES (1,Source.id)
WHEN NOT MATCHED BY SOURCE AND Target.owner = 1 THEN DELETE;
SELECT name FROM dbo.bar ORDER BY id;
-- @step batch
DELETE dbo.foo; TRUNCATE TABLE dbo.bar;
MERGE dbo.foo WITH (SERIALIZABLE) AS Target
USING (VALUES (N'a'),(N'b')) AS Source(id)
ON (Target.owner = 1 AND Target.name = Source.id)
WHEN NOT MATCHED BY TARGET THEN INSERT (owner,name) VALUES (1,Source.id)
WHEN NOT MATCHED BY SOURCE AND Target.owner = 1 THEN DELETE;
SELECT name FROM dbo.bar ORDER BY id;
-- @step batch
DELETE dbo.foo; TRUNCATE TABLE dbo.bar;
MERGE dbo.foo WITH (SERIALIZABLE) AS Target
USING (VALUES (N'c'),(N'a'),(N'd'),(N'b')) AS Source(id)
ON (Target.owner = 1 AND Target.name = Source.id)
WHEN NOT MATCHED BY TARGET THEN INSERT (owner,name) VALUES (1,Source.id)
WHEN NOT MATCHED BY SOURCE AND Target.owner = 1 THEN DELETE;
SELECT name FROM dbo.bar ORDER BY id;
-- @step batch
DELETE dbo.foo; TRUNCATE TABLE dbo.bar;
MERGE dbo.foo WITH (SERIALIZABLE) AS Target
USING (VALUES (N'd'),(N'c'),(N'b'),(N'a')) AS Source(id)
ON (Target.owner = 1 AND Target.name = Source.id)
WHEN NOT MATCHED BY TARGET THEN INSERT (owner,name) VALUES (1,Source.id)
WHEN NOT MATCHED BY SOURCE AND Target.owner = 1 THEN DELETE;
SELECT name FROM dbo.bar ORDER BY id;
