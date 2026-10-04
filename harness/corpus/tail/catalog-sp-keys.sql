-- sp_pkeys / sp_fkeys: names are compared, not patterns; qualifier
-- errors 15250 (sp_pkeys line 17, sp_fkeys foreign qualifier line 28 then
-- primary qualifier line 37), under TRY too; without @pktable_name the
-- rules are CASCADE 0 or 1.
-- @step setup
CREATE TABLE dbo.kp(id INT CONSTRAINT PK_kp PRIMARY KEY, a INT);
CREATE TABLE dbo.kc(id INT, p INT CONSTRAINT FK_kc_kp REFERENCES dbo.kp(id) ON DELETE CASCADE ON UPDATE SET NULL);
-- @step batch
EXEC sp_pkeys 'k_'
-- @step batch
EXEC sp_pkeys '%'
-- @step batch
EXEC sp_pkeys NULL
-- @step batch
EXEC sp_pkeys 'KP', 'DBO'
-- @step batch
DECLARE @r INT; EXEC @r = sp_pkeys 'kp', NULL, 'tempdb'; SELECT @r AS status, @@ERROR AS error
-- @step batch
BEGIN TRY EXEC sp_pkeys 'kp', 'dbo', 'tempdb' END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS number, ERROR_PROCEDURE() AS proc_name, ERROR_LINE() AS line END CATCH
-- @step batch
EXEC sp_fkeys @fktable_name = 'kc'
-- @step batch
EXEC sp_fkeys @pktable_name = 'kp'
-- @step batch
EXEC sp_fkeys 'kp', '%'
-- @step batch
EXEC sp_fkeys @pktable_name = 'kp', @pktable_qualifier = 'tempdb'
-- @step batch
EXEC sp_fkeys @pktable_name = 'kp', @pktable_qualifier = 'tempdb', @fktable_name = 'kc', @fktable_qualifier = 'tempdb'
-- @step batch
EXEC sp_fkeys @fktable_name = 'kc', @fktable_qualifier = 'TEMPDB'; SELECT @@ERROR AS error
-- @step batch
BEGIN TRY EXEC sp_fkeys NULL END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS number, ERROR_PROCEDURE() AS proc_name, ERROR_LINE() AS line END CATCH
-- @step batch
BEGIN TRY EXEC sp_fkeys @fktable_name = 'kc', @fktable_qualifier = 'tempdb' END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS number, ERROR_PROCEDURE() AS proc_name, ERROR_LINE() AS line END CATCH
