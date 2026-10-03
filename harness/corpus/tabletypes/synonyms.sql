-- CREATE/DROP SYNONYM: resolution in SELECT, INSERT/UPDATE/DELETE and EXEC
-- (also by RPC name), sys.synonyms, sys.objects type SN, OBJECT_ID, a
-- synonym of a missing object (5313), name clashes (2714) and DROP TABLE /
-- DROP SYNONYM of the wrong kind (3705).
-- @step setup
CREATE TABLE dbo.t (id int PRIMARY KEY, v nvarchar(10));
INSERT INTO dbo.t VALUES (1, N'a'), (2, N'b');
-- @step setup
CREATE PROCEDURE dbo.pr @x int AS SELECT @x * 2 AS y;
-- @step batch
CREATE SYNONYM dbo.s FOR dbo.t;
CREATE SYNONYM sp FOR dbo.pr;
CREATE SYNONYM dbo.snone FOR dbo.nothing;
CREATE SYNONYM dbo.s3 FOR otherdb.dbo.t;
-- @step batch
SELECT * FROM dbo.s ORDER BY id;
SELECT x.v FROM s AS x WHERE x.id = 2;
SELECT s.v FROM s WHERE s.id = 1;
INSERT INTO dbo.s VALUES (3, N'c');
INSERT INTO s (id, v) SELECT id + 10, v FROM dbo.s WHERE id < 3;
UPDATE s SET v = N'z' WHERE id = 3;
DELETE FROM s WHERE id = 1;
SELECT * FROM dbo.t ORDER BY id;
EXEC sp 21;
EXEC dbo.sp @x = 4;
-- @step proc dbo.sp
-- @param @x int = 5
-- @step batch
SELECT * FROM dbo.snone;
-- @step batch
INSERT INTO dbo.snone VALUES (1);
-- @step batch
SELECT name, base_object_name, type, type_desc, parent_object_id, schema_id, principal_id, is_ms_shipped, is_published, is_schema_published FROM sys.synonyms ORDER BY name;
SELECT name, type, type_desc, parent_object_id FROM sys.objects WHERE type = 'SN' ORDER BY name;
SELECT CASE WHEN OBJECT_ID('dbo.s') IS NOT NULL THEN 1 ELSE 0 END AS a, CASE WHEN OBJECT_ID('dbo.s', 'SN') IS NOT NULL THEN 1 ELSE 0 END AS b, OBJECT_ID('dbo.s', 'U') AS c;
SELECT OBJECT_NAME(OBJECT_ID('s')) AS n, OBJECT_SCHEMA_NAME(OBJECT_ID('s')) AS sc, OBJECTPROPERTY(OBJECT_ID('s'), 'IsTable') AS it;
-- @step batch
CREATE SYNONYM dbo.s FOR dbo.t;
-- @step batch
CREATE SYNONYM dbo.t FOR dbo.t;
-- @step batch
CREATE TABLE dbo.s (x int);
-- @step batch
CREATE SYNONYM nope.s FOR dbo.t;
-- @step batch
DROP TABLE dbo.s;
-- @step batch
DROP SYNONYM dbo.t;
-- @step batch
DROP SYNONYM dbo.s;
DROP SYNONYM IF EXISTS dbo.s;
SELECT COUNT(*) AS c FROM sys.synonyms;
-- @step batch
DROP SYNONYM dbo.s;
-- @step batch
SELECT * FROM dbo.s;
-- @step batch
DROP SYNONYM sp, dbo.snone, s3;
SELECT COUNT(*) AS c FROM sys.synonyms;
