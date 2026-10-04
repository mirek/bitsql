-- ALTER SCHEMA s TRANSFER [OBJECT:: | TYPE:: | XML SCHEMA COLLECTION::]
-- name: no DONE of its own; the object keeps its id and takes its
-- constraints along; modules keep their text; transferring into the own
-- schema does nothing; transactional. Errors are statement-level with
-- CurCmd 170 (no DONE before CATCH when caught): 15151 (missing object,
-- type, xml schema collection or target schema; constraints are not
-- transferable), 15530 (name taken), 33144 (temp table), 2710 (sys).
-- @step setup
CREATE TABLE dbo.t1 (id int NOT NULL CONSTRAINT PK_t1 PRIMARY KEY, v int CONSTRAINT DF_t1_v DEFAULT 0, CONSTRAINT CK_t1 CHECK (v >= 0)); INSERT INTO dbo.t1 VALUES (1, 1);
-- @step setup
CREATE SCHEMA s2
-- @step setup
CREATE VIEW dbo.v1 AS SELECT id FROM dbo.t1
-- @step setup
CREATE PROCEDURE dbo.p1 AS SELECT 1 AS x
-- @step batch
DECLARE @id int = OBJECT_ID('dbo.t1'); ALTER SCHEMA s2 TRANSFER dbo.t1; SELECT CASE WHEN OBJECT_ID('s2.t1') = @id THEN 1 ELSE 0 END AS same_id, OBJECT_ID('dbo.t1') AS old_id
-- @step batch
SELECT o.name, SCHEMA_NAME(o.schema_id) AS sch, o.type FROM sys.objects o WHERE o.name IN ('t1', 'PK_t1', 'DF_t1_v', 'CK_t1', 'v1', 'p1') ORDER BY o.name
-- @step batch
SELECT * FROM s2.t1
-- @step batch
ALTER SCHEMA s2 TRANSFER OBJECT::dbo.v1; ALTER SCHEMA s2 TRANSFER p1
-- @step batch
EXEC s2.p1
-- @step batch
ALTER SCHEMA s2 TRANSFER dbo.nothere
-- @step batch
ALTER SCHEMA nosuch TRANSFER s2.t1
-- @step batch
ALTER SCHEMA s2 TRANSFER s2.t1
-- @step batch
CREATE TABLE dbo.t1 (a int); ALTER SCHEMA s2 TRANSFER dbo.t1
-- @step batch
SELECT 1 AS a; ALTER SCHEMA dbo TRANSFER s2.t1; SELECT 2 AS b
-- @step batch
BEGIN TRAN; ALTER SCHEMA dbo TRANSFER s2.v1; SELECT SCHEMA_NAME(schema_id) AS sch FROM sys.objects WHERE name = 'v1'; ROLLBACK; SELECT SCHEMA_NAME(schema_id) AS sch FROM sys.objects WHERE name = 'v1'
-- @step batch
ALTER SCHEMA s2 TRANSFER dbo.PK_t1
-- @step batch
ALTER SCHEMA s2 TRANSFER TYPE::dbo.nothere
-- @step setup
CREATE TYPE dbo.ty FROM int;
-- @step batch
ALTER SCHEMA s2 TRANSFER TYPE::dbo.ty; SELECT SCHEMA_NAME(schema_id) AS sch FROM sys.types WHERE name = 'ty'
-- @step batch
ALTER SCHEMA s2 TRANSFER #tmp
-- @step batch
ALTER SCHEMA sys TRANSFER dbo.t1
-- @step batch
BEGIN TRY ALTER SCHEMA s2 TRANSFER dbo.zz END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, ERROR_MESSAGE() AS m END CATCH
-- @step batch
ALTER SCHEMA s2 TRANSFER XML SCHEMA COLLECTION::dbo.x
