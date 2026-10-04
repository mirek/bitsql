-- Column type arguments in CREATE TABLE / CREATE TYPE (183, 2750, 1001,
-- 1002), column names colliding under the database collation (2705 state
-- 3), CREATE TYPE named like a system type (219), and the sys.objects row
-- of a table type's table (TT_<name>_<object id hex>, schema sys).
-- @step batch
CREATE TABLE dbo.x1(a INT, bad DECIMAL(2,3))
-- @step batch
CREATE TABLE dbo.x2(a INT, b INT, bad DECIMAL(39))
-- @step batch
CREATE TABLE dbo.x3(a INT, bad FLOAT(0))
-- @step batch
CREATE TABLE dbo.x4(a INT, b INT, bad FLOAT(54))
-- @step batch
CREATE TABLE dbo.x5(bad DECIMAL(0))
-- @step batch
CREATE TABLE dbo.x6(bad VARCHAR(0))
-- @step batch
CREATE TABLE dbo.x7([Ä] INT, [ä] INT)
-- @step batch
CREATE TABLE dbo.x8(a INT, [A] INT)
-- @step batch
CREATE TYPE dbo.[varchar] AS TABLE (x INT)
-- @step batch
CREATE TYPE dbo.[sysname] FROM INT
-- @step batch
CREATE TYPE [int] FROM INT
-- @step batch
CREATE TABLE dbo.x9(a INT, bad TIME(8))
-- @step batch
CREATE TABLE dbo.x10(a INT, bad NUMERIC(10,11))
-- @step batch
CREATE TABLE dbo.x11(a INT,
  b DATETIME2(9))
-- @step batch
CREATE TYPE dbo.TTx AS TABLE (id INT, [Ö] INT);
SELECT o.schema_id, o.type, o.type_desc, o.is_ms_shipped, o.parent_object_id,
  CASE WHEN o.name = 'TT_TTx_' + CONVERT(varchar(8), CONVERT(binary(4), t.type_table_object_id), 2) THEN 1 ELSE 0 END AS name_has_id,
  LEFT(OBJECT_NAME(t.type_table_object_id), 7) AS object_name, OBJECT_SCHEMA_NAME(t.type_table_object_id) AS object_schema
FROM sys.objects o JOIN sys.table_types t ON t.type_table_object_id = o.object_id;
SELECT COUNT(*) AS shipped FROM sys.objects WHERE is_ms_shipped = 1
