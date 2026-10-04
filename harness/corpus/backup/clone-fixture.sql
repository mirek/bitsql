-- Fixture cloning through BACKUP / RESTORE (external compatibility report):
-- back up the case database with FORMAT, NAME, COMPRESSION, read RESTORE
-- HEADERONLY / FILELISTONLY, restore a copy WITH REPLACE and MOVE of both
-- logical files, then check the copy's data and programmable objects
-- (view, procedure, function, trigger, sequence, identity), that copy and
-- original are independent, that a second RESTORE … WITH REPLACE resets
-- the copy, the copy's sys.database_files and the msdb history rows.
-- Names derive from DB_NAME() ("{db}-copy", "{db}.bak") so the oracle's
-- server-wide state stays per run; values SQL Server derives from pages,
-- clocks and random GUIDs are masked (bitsql synthesizes them).
-- @step setup
CREATE TABLE dbo.t (id int IDENTITY(1,1) CONSTRAINT pk_t PRIMARY KEY, v nvarchar(20) NOT NULL);
INSERT dbo.t (v) VALUES (N'a'), (N'b');
CREATE SEQUENCE dbo.s AS int START WITH 10;
-- @step setup
CREATE VIEW dbo.vw AS SELECT id, v FROM dbo.t WHERE id > 1
-- @step setup
CREATE PROCEDURE dbo.p AS SELECT COUNT(*) AS n FROM dbo.t
-- @step setup
CREATE FUNCTION dbo.f (@x int) RETURNS int AS BEGIN RETURN @x * 2 END
-- @step setup
CREATE TRIGGER dbo.tr ON dbo.t AFTER INSERT AS
SET NOCOUNT ON;
UPDATE dbo.t SET v = v + N'!' WHERE id IN (SELECT id FROM inserted)
-- @step setup
SELECT NEXT VALUE FOR dbo.s AS first_value
-- @step batch
-- @mask info/0/message
-- @mask info/1/message
-- @mask info/2/message
DECLARE @d sysname = DB_NAME(), @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak';
BACKUP DATABASE @d TO DISK = @p WITH FORMAT, NAME = N'fixture', COMPRESSION;
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
RESTORE HEADERONLY FROM DISK = @p;
-- @step batch
-- @mask sets/0/rows/1/0
-- @mask sets/0/rows/1/1
-- @mask sets/0/rows/*/9
-- @mask sets/0/rows/*/12
-- @mask sets/0/rows/*/16
-- @mask sets/0/rows/*/17
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak';
RESTORE FILELISTONLY FROM DISK = @p;
-- @step batch
-- @mask info/0/message
-- @mask info/1/message
-- @mask info/2/message
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak',
  @copy sysname = DB_NAME() + N'-copy', @data sysname = DB_NAME(), @log sysname = DB_NAME() + N'_log';
DECLARE @mdf nvarchar(260) = N'/var/opt/mssql/data/' + @copy + N'.mdf', @ldf nvarchar(260) = N'/var/opt/mssql/data/' + @copy + N'.ldf';
RESTORE DATABASE @copy FROM DISK = @p WITH REPLACE, MOVE @data TO @mdf, MOVE @log TO @ldf;
-- @step batch
DECLARE @sql nvarchar(max) = N'USE ' + QUOTENAME(DB_NAME() + N'-copy') + N';
SELECT id, v FROM dbo.t ORDER BY id;
SELECT id, v FROM dbo.vw;
EXEC dbo.p;
SELECT dbo.f(21) AS f;
SELECT NEXT VALUE FOR dbo.s AS next_value;
INSERT dbo.t (v) VALUES (N''c'');
SELECT id, v FROM dbo.t ORDER BY id;
SELECT IDENT_CURRENT(N''dbo.t'') AS ident;
SELECT name, type FROM sys.objects WHERE is_ms_shipped = 0 ORDER BY name;';
EXEC (@sql);
-- @step batch
SELECT id, v FROM dbo.t ORDER BY id;
SELECT NEXT VALUE FOR dbo.s AS next_value;
INSERT dbo.t (v) VALUES (N'x');
SELECT id, v FROM dbo.t ORDER BY id;
-- @step batch
DECLARE @oid int = OBJECT_ID(N'dbo.t');
DECLARE @sql nvarchar(max) = N'USE ' + QUOTENAME(DB_NAME() + N'-copy') + N';
SELECT CASE WHEN OBJECT_ID(N''dbo.t'') = @oid THEN 1 ELSE 0 END AS same_object_id;
SELECT file_id, type_desc, physical_name, CASE WHEN name = @src THEN N''src'' WHEN name = @src + N''_log'' THEN N''src_log'' ELSE name END AS logical
FROM sys.database_files ORDER BY file_id;
DELETE FROM dbo.t;';
DECLARE @src sysname = DB_NAME();
EXEC sp_executesql @sql, N'@oid int, @src sysname', @oid, @src;
-- @step batch
-- @mask info/0/message
-- @mask info/1/message
-- @mask info/2/message
DECLARE @p nvarchar(260) = N'/var/opt/mssql/data/' + DB_NAME() + N'.bak',
  @copy sysname = DB_NAME() + N'-copy', @data sysname = DB_NAME(), @log sysname = DB_NAME() + N'_log';
DECLARE @mdf nvarchar(260) = N'/var/opt/mssql/data/' + @copy + N'.mdf', @ldf nvarchar(260) = N'/var/opt/mssql/data/' + @copy + N'.ldf';
RESTORE DATABASE @copy FROM DISK = @p WITH REPLACE, MOVE @data TO @mdf, MOVE @log TO @ldf;
-- @step batch
DECLARE @sql nvarchar(max) = N'USE ' + QUOTENAME(DB_NAME() + N'-copy') + N';
SELECT id, v FROM dbo.t ORDER BY id;
INSERT dbo.t (v) VALUES (N''d'');
SELECT id, v FROM dbo.t ORDER BY id;
SELECT NEXT VALUE FOR dbo.s AS next_value;';
EXEC (@sql);
-- @step batch
SELECT name, description, type, position, database_name, is_copy_only, has_backup_checksums,
  recovery_model, compatibility_level, collation_name, software_major_version, database_version,
  flags, compression_algorithm, first_family_number, last_media_number, mtf_minor_version, sort_order, code_page
FROM msdb.dbo.backupset WHERE database_name = DB_NAME() ORDER BY backup_set_id;
SELECT f.physical_device_name, f.device_type, f.family_sequence_number, f.logical_device_name, f.physical_block_size,
  f.mirror, f.media_count, m.media_family_count, m.software_name, m.software_vendor_id, m.is_compressed, m.mirror_count
FROM msdb..backupmediafamily f
JOIN msdb..backupmediaset m ON m.media_set_id = f.media_set_id
JOIN msdb..backupset s ON s.media_set_id = f.media_set_id
WHERE s.database_name = DB_NAME() ORDER BY s.backup_set_id;
SELECT h.destination_database_name, h.restore_type, h.[replace], h.recovery, h.restart, h.device_count, h.stop_at, s.name
FROM msdb.dbo.restorehistory h JOIN msdb.dbo.backupset s ON s.backup_set_id = h.backup_set_id
WHERE h.destination_database_name = DB_NAME() + N'-copy' ORDER BY h.restore_history_id;
SELECT f.file_number, f.destination_phys_drive, f.destination_phys_name
FROM msdb.dbo.restorefile f JOIN msdb.dbo.restorehistory h ON h.restore_history_id = f.restore_history_id
WHERE h.destination_database_name = DB_NAME() + N'-copy' ORDER BY f.restore_history_id, f.file_number;
SELECT f.file_number, f.file_type, f.filegroup_name, f.page_size, f.source_file_block_size, f.physical_drive,
  f.state, f.state_desc, f.drop_lsn, f.is_readonly, f.is_present, CASE WHEN f.logical_name = DB_NAME() THEN N'src' ELSE N'other' END AS logical
FROM msdb.dbo.backupfile f JOIN msdb.dbo.backupset s ON s.backup_set_id = f.backup_set_id
WHERE s.database_name = DB_NAME() ORDER BY f.file_number;
-- @step batch
DECLARE @sql nvarchar(max) = N'DROP DATABASE ' + QUOTENAME(DB_NAME() + N'-copy');
EXEC (@sql);
