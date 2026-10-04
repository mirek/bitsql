-- BACKUP of a database that does not exist: 911 (state 11, LOG 10) + 3013,
-- statement-level (DONE 228/235), TRY catches 3013; unknown options are
-- the parse error 155 (state 1 bare, 2 with a value) for the whole batch.
-- @step batch
BACKUP DATABASE nosuch TO DISK=N'/tmp/x.bak'; SELECT 1 AS a
-- @step batch
BACKUP LOG nosuch TO DISK=N'/tmp/x.bak'
-- @step batch
BACKUP DATABASE nosuch TO DISK=N'/tmp/x.bak' WITH INIT, COMPRESSION, STATS = 10, FORMAT, COPY_ONLY, CHECKSUM, NAME = N'x', DESCRIPTION = N'y'
-- @step batch
BACKUP DATABASE nosuch TO DISK=N'/tmp/x.bak' WITH Bogus = 5
-- @step batch
BEGIN TRY BACKUP DATABASE nosuch TO DISK=N'/tmp/x.bak' END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, ERROR_MESSAGE() AS m END CATCH
-- @step batch
BACKUP DATABASE [nosuch] TO DISK='x' WITH DIFFERENTIAL
-- @step batch
BACKUP DATABASE nosuch TO DISK='a', DISK='b'
-- @step batch
SELECT 1 AS a; BACKUP DATABASE nosuch TO DISK='a' WITH BOGUS
-- @step batch
DECLARE @d sysname = N'nosuch'; BACKUP DATABASE @d TO DISK='a'
-- @step batch
BACKUP DATABASE NoSuch TO DISK='a'; SELECT @@ERROR AS e
-- @step batch
BACKUP DATABASE nosuch TO DISK='a' WITH NOINIT, SKIP, NOREWIND, NOUNLOAD, NO_COMPRESSION, NO_CHECKSUM, CONTINUE_AFTER_ERROR, BUFFERCOUNT = 5, MAXTRANSFERSIZE = 65536, BLOCKSIZE = 512, MEDIANAME = N'm', RETAINDAYS = 1
-- @step batch
BACKUP DATABASE nosuch TO DISK='a' WITH compression
