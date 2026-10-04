-- A view or inline function whose body no longer binds: the binding error,
-- then 4413 naming the outermost module as written (line 13 when the name
-- is schema-qualified). A compile error: TRY does not catch it.
-- @step setup
CREATE TABLE dbo.b(id int, v int);
-- @step setup
CREATE VIEW dbo.bv AS SELECT MIN(v) AS result FROM dbo.b
-- @step setup
CREATE VIEW dbo.bn AS SELECT result FROM bv
-- @step setup
CREATE FUNCTION dbo.f() RETURNS TABLE AS RETURN SELECT v FROM dbo.b
-- @step setup
ALTER TABLE dbo.b DROP COLUMN v
-- @step batch
SELECT result FROM BV
-- @step batch
SELECT result FROM dbo.bn
-- @step batch
SELECT * FROM dbo.f()
-- @step batch
SELECT x.result FROM dbo.b CROSS JOIN dbo.bv AS x
