-- Catalog views of tempdb list the session's temp tables: internal names
-- padded with '_' to 128 characters (12 trailing hex digits, not compared),
-- columns, indexes, INFORMATION_SCHEMA with catalog 'tempdb'.
-- @step setup
CREATE TABLE #foo(id int NOT NULL PRIMARY KEY, v varchar(5))
-- @step batch
SELECT LEN(name) AS len, LEFT(name, 6) AS head, SUBSTRING(name, 5, 3) AS mid, type, type_desc, schema_id, parent_object_id, is_ms_shipped FROM tempdb.sys.objects WHERE object_id = OBJECT_ID('tempdb..#foo')
-- @step batch
SELECT COUNT(*) AS n FROM tempdb.sys.objects WHERE name LIKE '#foo%'
-- @step batch
SELECT COUNT(*) AS n FROM tempdb.sys.objects WHERE name = '#foo'
-- @step batch
SELECT LEN(name) AS len, LEFT(name, 4) AS head FROM tempdb.sys.tables WHERE object_id = OBJECT_ID('tempdb..#foo')
-- @step batch
SELECT name, column_id, system_type_id, max_length, is_nullable FROM tempdb.sys.columns WHERE object_id = OBJECT_ID('tempdb..#foo') ORDER BY column_id
-- @step batch
SELECT type_desc, is_primary_key, LEFT(name, 6) AS head FROM tempdb.sys.indexes WHERE object_id = OBJECT_ID('tempdb..#foo')
-- @step batch
SELECT TABLE_CATALOG, TABLE_SCHEMA, LEFT(TABLE_NAME, 4) AS head, LEN(TABLE_NAME) AS len FROM tempdb.INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME LIKE '#foo%'
-- @step batch
SELECT COLUMN_NAME, TABLE_CATALOG FROM tempdb.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME LIKE '#foo[_]%' ORDER BY ORDINAL_POSITION
-- @step batch
SELECT OBJECT_ID('tempdb..#foo') - (SELECT object_id FROM tempdb.sys.tables WHERE name LIKE '#foo[_]%') AS diff
-- @step batch
CREATE TABLE #h(a int); SELECT name FROM tempdb.sys.columns WHERE object_id = OBJECT_ID('tempdb..#h')
-- @step batch
SELECT DB_NAME() AS d, name FROM tempdb.sys.schemas WHERE schema_id = 1
