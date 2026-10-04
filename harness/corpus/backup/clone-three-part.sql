-- The reporter's clone workflow read from master with three-part names:
-- BACKUP the case database, change it, RESTORE a copy (fixed name
-- bitsql_bk3p_copy, dropped first and last) WITH REPLACE and MOVE, then
-- from master: DB_ID / DB_NAME / sys.databases see the copy, SELECT and
-- INSERT through copy.dbo.t (the copy's identity continues from the
-- backup, independently of the original's).
-- @step setup
CREATE TABLE dbo.t (id int IDENTITY(1,1) CONSTRAINT pk_t PRIMARY KEY, v nvarchar(20) NOT NULL);
INSERT dbo.t (v) VALUES (N'a'), (N'b');
IF DB_ID(N'bitsql_bk3p_copy') IS NOT NULL DROP DATABASE bitsql_bk3p_copy;
-- @step batch
-- @mask info/0/message
-- @mask info/1/message
-- @mask info/2/message
DECLARE @d sysname = DB_NAME();
BACKUP DATABASE @d TO DISK = N'/var/opt/mssql/data/bitsql_bk3p.bak' WITH FORMAT, NAME = N'fixture', COMPRESSION;
-- @step batch
INSERT dbo.t (v) VALUES (N'x');
SELECT id, v FROM dbo.t ORDER BY id;
-- @step batch
-- @mask info/1/message
-- @mask info/2/message
-- @mask info/3/message
DECLARE @d sysname = DB_NAME(), @l sysname = DB_NAME() + N'_log';
USE master;
RESTORE DATABASE bitsql_bk3p_copy FROM DISK = N'/var/opt/mssql/data/bitsql_bk3p.bak'
  WITH REPLACE, MOVE @d TO N'/var/opt/mssql/data/bitsql_bk3p_copy.mdf', MOVE @l TO N'/var/opt/mssql/data/bitsql_bk3p_copy.ldf';
-- @step batch
SELECT DB_NAME() AS current_db, CASE WHEN DB_ID(N'bitsql_bk3p_copy') > 4 THEN 1 ELSE 0 END AS has_id,
  DB_NAME(DB_ID(N'bitsql_bk3p_copy')) AS copy_name;
SELECT name, state_desc, recovery_model_desc FROM sys.databases WHERE name = N'bitsql_bk3p_copy';
SELECT id, v FROM bitsql_bk3p_copy.dbo.t ORDER BY id;
INSERT bitsql_bk3p_copy.dbo.t (v) VALUES (N'c');
SELECT id, v FROM bitsql_bk3p_copy.dbo.t ORDER BY id;
SELECT COUNT(*) AS n FROM bitsql_bk3p_copy.sys.tables;
-- @step batch
DROP DATABASE bitsql_bk3p_copy;
