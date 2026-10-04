-- Object ids count per database: every fresh database's first object is
-- 1221579390 (stride 16000057) whatever other databases, temp tables or
-- table variables hold. ORMs list tables in object_id order (TypeORM reads
-- INFORMATION_SCHEMA.TABLES without ORDER BY), so a server-wide counter
-- reorders their catalog queries once another database has objects.
-- NOT EMULATED (fails on purpose): bitsql's counter is server-wide because
-- identity counters, compiled UDFs and key-range locks are keyed by object
-- id alone (roadmap: per-database object ids).
-- @step setup
IF DB_ID(N'bitsql_orm_object_ids') IS NOT NULL DROP DATABASE bitsql_orm_object_ids;
CREATE DATABASE bitsql_orm_object_ids;
-- @step setup
EXEC (N'USE bitsql_orm_object_ids; CREATE TABLE x1 (id int); CREATE TABLE x2 (id int); CREATE TABLE x3 (id int PRIMARY KEY);');
-- @step batch
CREATE TABLE #tmp (id int PRIMARY KEY);
DECLARE @tv TABLE (id int PRIMARY KEY);
CREATE TABLE a (id int CONSTRAINT a_pk PRIMARY KEY);
CREATE TABLE b (id int);
SELECT name, object_id FROM sys.objects WHERE is_ms_shipped = 0 ORDER BY object_id;
EXEC (N'USE bitsql_orm_object_ids; SELECT name, object_id FROM sys.objects WHERE is_ms_shipped = 0 AND name NOT LIKE N''PK%'' ORDER BY object_id;');
-- @step setup
DROP DATABASE bitsql_orm_object_ids;
