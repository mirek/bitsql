-- Untyped NULL must adopt the mixed VALUES column type before assignment.
-- @step setup
CREATE TABLE dbo.foo (v datetime2 NULL);
-- @step batch
INSERT dbo.foo VALUES (NULL), (N'2026-01-01');
SELECT v FROM dbo.foo ORDER BY v;
-- @step batch
TRUNCATE TABLE dbo.foo;
INSERT dbo.foo VALUES (NULL), (CAST(N'2026-01-01' AS datetime2));
SELECT v FROM dbo.foo ORDER BY v;
-- @step batch
TRUNCATE TABLE dbo.foo;
INSERT dbo.foo VALUES (CAST(NULL AS datetime2)), (N'2026-01-01');
SELECT v FROM dbo.foo ORDER BY v;
-- @step batch
TRUNCATE TABLE dbo.foo;
INSERT dbo.foo VALUES (NULL);
SELECT v FROM dbo.foo;
-- @step batch
TRUNCATE TABLE dbo.foo;
INSERT dbo.foo VALUES (N'2026-01-01'), (NULL), (NULL);
SELECT v FROM dbo.foo ORDER BY v;
