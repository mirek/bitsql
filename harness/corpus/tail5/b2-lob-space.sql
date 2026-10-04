-- sys.tables.lob_data_space_id stays 1 once a table had a LOB column
-- (dropped, narrowed, renamed, TRUNCATE, SELECT INTO), but a rolled-back
-- ADD leaves 0.
-- @step setup
CREATE TABLE dbo.w1 (id int, p varchar(max)); ALTER TABLE dbo.w1 DROP COLUMN p
-- @step batch
SELECT lob_data_space_id FROM sys.tables WHERE name = 'w1'
-- @step batch
TRUNCATE TABLE dbo.w1; SELECT lob_data_space_id FROM sys.tables WHERE name = 'w1'
-- @step batch
CREATE TABLE dbo.w2 (id int); BEGIN TRAN; ALTER TABLE dbo.w2 ADD p xml; ROLLBACK; SELECT lob_data_space_id FROM sys.tables WHERE name = 'w2'
-- @step batch
CREATE TABLE dbo.w3 (id int, p nvarchar(max)); EXEC sp_rename 'dbo.w3', 'w4'; ALTER TABLE dbo.w4 DROP COLUMN p; SELECT lob_data_space_id FROM sys.tables WHERE name = 'w4'
-- @step batch
SELECT id, p INTO dbo.w6 FROM (SELECT 1 AS id, CAST('a' AS varchar(max)) AS p) x; ALTER TABLE dbo.w6 DROP COLUMN p; SELECT lob_data_space_id FROM sys.tables WHERE name = 'w6'
-- @step batch
CREATE TABLE dbo.w7 (id int, p varbinary(20)); ALTER TABLE dbo.w7 ALTER COLUMN p varbinary(max); ALTER TABLE dbo.w7 ALTER COLUMN p varbinary(20); SELECT lob_data_space_id FROM sys.tables WHERE name = 'w7'
-- @step batch
CREATE TABLE dbo.w8 (id int, p text); ALTER TABLE dbo.w8 DROP COLUMN p; SELECT lob_data_space_id FROM sys.tables WHERE name = 'w8'
