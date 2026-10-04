-- Backup sets on one backup file: FORMAT starts a new media set (position
-- 1), a plain BACKUP appends (NOINIT), INIT overwrites the sets but keeps
-- the media set and its compression (sets on a compressed media are
-- compressed), CHECKSUM and COPY_ONLY flags, RESTORE HEADERONLY of all
-- sets and WITH FILE = n, FILELISTONLY / VERIFYONLY WITH FILE = 2, a
-- case-insensitive device path, STATS = 50 and the "Processed n pages"
-- messages of an empty database ("{db}-m", so the log file's logical name
-- normalizes), a restore of set 2 with STATS and its sys.database_files.
-- @step setup
DECLARE @sql nvarchar(max) = N'CREATE DATABASE ' + QUOTENAME(DB_NAME() + N'-m');
EXEC (@sql);
-- @step batch
-- @mask info/4/message
DECLARE @d sysname = DB_NAME() + N'-m', @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'-m.bak';
BACKUP DATABASE @d TO DISK = @p WITH FORMAT, COMPRESSION, STATS = 50, NAME = N'one';
-- @step batch
-- @mask info/2/message
DECLARE @d sysname = DB_NAME() + N'-m', @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'-m.bak';
BACKUP DATABASE @d TO DISK = @p WITH DESCRIPTION = N'two', COPY_ONLY, CHECKSUM;
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
-- @mask sets/1/rows/*/8
-- @mask sets/1/rows/*/11
-- @mask sets/1/rows/*/12
-- @mask sets/1/rows/*/13
-- @mask sets/1/rows/*/14
-- @mask sets/1/rows/*/15
-- @mask sets/1/rows/*/16
-- @mask sets/1/rows/*/17
-- @mask sets/1/rows/*/18
-- @mask sets/1/rows/*/28
-- @mask sets/1/rows/*/30
-- @mask sets/1/rows/*/31
-- @mask sets/1/rows/*/33
-- @mask sets/1/rows/*/44
-- @mask sets/1/rows/*/50
-- @mask sets/1/rows/*/51
-- @mask sets/1/rows/*/57
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'-m.bak';
RESTORE HEADERONLY FROM DISK = @p;
RESTORE HEADERONLY FROM DISK = @p WITH FILE = 2;
-- @step batch
-- @mask sets/0/rows/*/9
-- @mask sets/0/rows/*/12
-- @mask sets/0/rows/*/16
-- @mask sets/0/rows/*/17
DECLARE @p nvarchar(260) = UPPER(N'/var/opt/mssql/data/') + DB_NAME() + N'-m.bak';
RESTORE FILELISTONLY FROM DISK = @p WITH FILE = 2;
RESTORE VERIFYONLY FROM DISK = @p WITH FILE = 2;
-- @step batch
-- @mask info/2/message
DECLARE @d sysname = DB_NAME() + N'-m', @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'-m.bak';
BACKUP DATABASE @d TO DISK = @p WITH INIT, NAME = N'three';
-- @step batch
-- @mask info/2/message
DECLARE @d sysname = DB_NAME() + N'-m', @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'-m.bak';
BACKUP DATABASE @d TO DISK = @p WITH NOINIT, NAME = N'four';
-- @step batch
SELECT s.name, s.description, s.position, DENSE_RANK() OVER (ORDER BY s.media_set_id) AS media, s.is_copy_only,
  s.has_backup_checksums, s.flags, s.compression_algorithm, m.is_compressed
FROM msdb.dbo.backupset s JOIN msdb.dbo.backupmediaset m ON m.media_set_id = s.media_set_id
WHERE s.database_name = DB_NAME() + N'-m' ORDER BY s.backup_set_id;
-- @step batch
-- @mask info/4/message
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'-m.bak', @copy sysname = DB_NAME() + N'-m2',
  @data sysname = DB_NAME() + N'-m', @log sysname = DB_NAME() + N'-m_log';
DECLARE @mdf nvarchar(260) = N'/var/opt/mssql/data/' + @copy + N'.mdf', @ldf nvarchar(260) = N'/var/opt/mssql/data/' + @copy + N'.ldf';
RESTORE DATABASE @copy FROM DISK = @p WITH FILE = 2, MOVE @data TO @mdf, MOVE @log TO @ldf, STATS = 50;
-- @step batch
DECLARE @sql nvarchar(max) = N'USE ' + QUOTENAME(DB_NAME() + N'-m2') + N';
SELECT file_id, type_desc, name, physical_name FROM sys.database_files ORDER BY file_id;';
EXEC (@sql);
-- @step batch
DECLARE @sql nvarchar(max) = N'DROP DATABASE ' + QUOTENAME(DB_NAME() + N'-m2') + N'; DROP DATABASE ' + QUOTENAME(DB_NAME() + N'-m');
EXEC (@sql);
