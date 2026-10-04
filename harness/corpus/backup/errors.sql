-- BACKUP / RESTORE errors: a missing backup file (3201 for every RESTORE
-- kind; TRY catches only the 3013, @@ERROR 3013), a transaction (3021,
-- also for a missing database; RESTORE HEADERONLY runs inside one),
-- tempdb (3147), files used by another database (1834 + 3156 per file,
-- 3119), an unknown MOVE logical name (3234), backup set positions out of
-- range (3287 for DATABASE, 4038 with per-kind 3013 texts), an existing
-- database of another family (3154, before 3234), a FULL-recovery
-- database of the same family without REPLACE (3159), the target in use
-- by this session (3102) and a database being restored over while another
-- session is inside it (3101).
-- @step setup
CREATE TABLE dbo.t (id int CONSTRAINT pk_t PRIMARY KEY);
DECLARE @sql nvarchar(max) = N'CREATE DATABASE ' + QUOTENAME(DB_NAME() + N'-other');
EXEC (@sql);
-- @step batch
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'-none.bak', @copy sysname = DB_NAME() + N'-copy';
RESTORE DATABASE @copy FROM DISK = @p;
RESTORE HEADERONLY FROM DISK = @p;
RESTORE FILELISTONLY FROM DISK = @p;
RESTORE VERIFYONLY FROM DISK = @p;
SELECT @@ERROR AS e;
-- @step batch
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'-none.bak', @copy sysname = DB_NAME() + N'-copy';
BEGIN TRY
  RESTORE DATABASE @copy FROM DISK = @p;
END TRY
BEGIN CATCH
  SELECT ERROR_NUMBER() AS n, ERROR_SEVERITY() AS s, ERROR_STATE() AS st, ERROR_MESSAGE() AS m;
END CATCH
-- @step batch
-- @mask info/0/message
-- @mask info/1/message
-- @mask info/2/message
DECLARE @d sysname = DB_NAME(), @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak';
BACKUP DATABASE @d TO DISK = @p WITH FORMAT;
-- @step batch
DECLARE @d sysname = DB_NAME(), @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak', @copy sysname = DB_NAME() + N'-copy';
BEGIN TRAN;
BACKUP DATABASE @d TO DISK = @p;
BACKUP DATABASE nosuch_db TO DISK = @p;
RESTORE DATABASE @copy FROM DISK = @p;
SELECT @@TRANCOUNT AS tc;
ROLLBACK;
-- @step batch
-- @mask sets/0/rows/*/8
-- @mask sets/0/rows/*/11
-- @mask sets/0/rows/*/12
-- @mask sets/0/rows/*/13
-- @mask sets/0/rows/*/14
-- @mask sets/0/rows/*/15
-- @mask sets/0/rows/*/16
-- @mask sets/0/rows/*/17
-- @mask sets/0/rows/*/18
-- @mask sets/0/rows/*/28
-- @mask sets/0/rows/*/30
-- @mask sets/0/rows/*/31
-- @mask sets/0/rows/*/33
-- @mask sets/0/rows/*/44
-- @mask sets/0/rows/*/50
-- @mask sets/0/rows/*/51
-- @mask sets/0/rows/*/57
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak';
BEGIN TRAN;
RESTORE HEADERONLY FROM DISK = @p;
ROLLBACK;
-- @step batch
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak';
BACKUP DATABASE tempdb TO DISK = @p;
RESTORE DATABASE tempdb FROM DISK = @p;
-- @step batch
-- @mask errors/2/message
-- @mask errors/3/message
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak', @copy sysname = DB_NAME() + N'-copy';
RESTORE DATABASE @copy FROM DISK = @p;
-- @step batch
-- @mask errors/0/message
-- @mask errors/1/message
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak', @copy sysname = DB_NAME() + N'-copy';
DECLARE @mdf nvarchar(260) = N'/var/opt/mssql/data/' + @copy + N'.mdf', @data sysname = UPPER(DB_NAME());
RESTORE DATABASE @copy FROM DISK = @p WITH MOVE @data TO @mdf;
-- @step batch
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak', @copy sysname = DB_NAME() + N'-copy';
RESTORE DATABASE @copy FROM DISK = @p WITH MOVE N'nope' TO N'/var/opt/mssql/data/nope.mdf';
-- @step batch
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak', @copy sysname = DB_NAME() + N'-copy';
RESTORE DATABASE @copy FROM DISK = @p WITH FILE = 9, REPLACE;
RESTORE FILELISTONLY FROM DISK = @p WITH FILE = 9;
RESTORE HEADERONLY FROM DISK = @p WITH FILE = 9;
RESTORE VERIFYONLY FROM DISK = @p WITH FILE = 9;
RESTORE VERIFYONLY FROM DISK = @p WITH FILE = 1;
-- @step batch
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak', @other sysname = DB_NAME() + N'-other';
RESTORE DATABASE @other FROM DISK = @p WITH MOVE N'nope' TO N'/var/opt/mssql/data/nope.mdf';
RESTORE DATABASE @other FROM DISK = @p;
-- @step batch
-- @mask info/0/message
-- @mask info/1/message
-- @mask info/2/message
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak',
  @copy sysname = DB_NAME() + N'-copy', @data sysname = DB_NAME(), @log sysname = DB_NAME() + N'_log';
DECLARE @mdf nvarchar(260) = N'/var/opt/mssql/data/' + @copy + N'.mdf', @ldf nvarchar(260) = N'/var/opt/mssql/data/' + @copy + N'.ldf';
RESTORE DATABASE @copy FROM DISK = @p WITH MOVE @data TO @mdf, MOVE @log TO @ldf;
-- @step batch
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak',
  @copy sysname = DB_NAME() + N'-copy', @data sysname = DB_NAME(), @log sysname = DB_NAME() + N'_log';
DECLARE @mdf nvarchar(260) = N'/var/opt/mssql/data/' + @copy + N'.mdf', @ldf nvarchar(260) = N'/var/opt/mssql/data/' + @copy + N'.ldf';
RESTORE DATABASE @copy FROM DISK = @p WITH MOVE @data TO @mdf, MOVE @log TO @ldf;
-- @step batch
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak', @copy sysname = DB_NAME() + N'-copy';
DECLARE @sql nvarchar(max) = N'USE ' + QUOTENAME(@copy) + N'; RESTORE DATABASE ' + QUOTENAME(@copy) + N' FROM DISK = @p WITH REPLACE;';
EXEC sp_executesql @sql, N'@p nvarchar(260)', @p;
-- @step batch conn=2 async
DECLARE @sql nvarchar(max) = N'USE ' + QUOTENAME(DB_NAME() + N'-copy') + N'; WAITFOR DELAY ''00:00:03''; SELECT DB_NAME() AS db;';
EXEC (@sql);
-- @step batch
-- @mask info/1/message
-- @mask info/2/message
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak', @copy sysname = DB_NAME() + N'-copy';
RESTORE DATABASE @copy FROM DISK = @p WITH REPLACE;
-- @step await conn=2
-- @step batch
DECLARE @sql nvarchar(max) = N'DROP DATABASE ' + QUOTENAME(DB_NAME() + N'-copy') + N'; DROP DATABASE ' + QUOTENAME(DB_NAME() + N'-other');
EXEC (@sql);
