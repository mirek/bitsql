-- json columns: values are normalized and validated on INSERT/UPDATE (13609
-- ends the batch), defaults, SELECT INTO, table variables, temp tables,
-- ALTER TABLE ADD / ALTER COLUMN (nvarchar → json validates, json →
-- nvarchar is 257), and the catalog: sys.columns/sys.types 244, max_length
-- -1, no collation; INFORMATION_SCHEMA DATA_TYPE json; sp_help Type json;
-- sp_columns leaves json columns out; describe reports varchar(max)
-- Latin1_General_100_BIN2_UTF8; lob_data_space_id is set.
-- @step batch
CREATE TABLE dbo.tj (id int NOT NULL PRIMARY KEY, j json NULL, k json NOT NULL CONSTRAINT df_tj_k DEFAULT ('{ }'));
INSERT dbo.tj (id, j) VALUES (1, N'{"a" : 1}'), (2, '[1, 2]'), (3, NULL);
SELECT id, j, k FROM dbo.tj ORDER BY id
-- @step batch
INSERT dbo.tj (id, j) VALUES (4, N'bad'); SELECT 'not reached' AS x
-- @step batch
SELECT COUNT(*) AS n FROM dbo.tj
-- @step batch
INSERT dbo.tj (id, j) VALUES (5, 5)
-- @step batch
INSERT dbo.tj (id, j) VALUES (6, 0x5B5D)
-- @step batch
INSERT dbo.tj (id, j) SELECT 7, CAST(N'[ 7 ]' AS nvarchar(10));
UPDATE dbo.tj SET j = N'{"b" : [true]}' WHERE id = 1;
SELECT id, j FROM dbo.tj ORDER BY id
-- @step batch
UPDATE dbo.tj SET j = N'nope' WHERE id = 2; SELECT 'not reached' AS x
-- @step batch
SELECT id, j FROM dbo.tj WHERE id = 2
-- @step batch
SELECT c.name, c.system_type_id, c.user_type_id, c.max_length, c.precision, c.scale, c.collation_name, c.is_nullable, c.is_ansi_padded, TYPE_NAME(c.user_type_id) AS tn FROM sys.columns c WHERE c.object_id = OBJECT_ID('dbo.tj') ORDER BY c.column_id
-- @step batch
SELECT name, system_type_id, user_type_id, max_length, precision, scale, collation_name, is_nullable, is_user_defined FROM sys.types WHERE name = 'json'
-- @step batch
SELECT TYPE_ID('json') AS t, TYPE_NAME(244) AS n, COLUMNPROPERTY(OBJECT_ID('dbo.tj'), 'j', 'Precision') AS p, COL_LENGTH('dbo.tj', 'j') AS l
-- @step batch
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, CHARACTER_OCTET_LENGTH, COLLATION_NAME, CHARACTER_SET_NAME, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'tj' ORDER BY ORDINAL_POSITION
-- @step batch
SELECT lob_data_space_id FROM sys.tables WHERE name = 'tj'
-- @step batch
EXEC sp_columns 'tj'
-- @step batch
EXEC sp_describe_first_result_set N'SELECT j, k, CAST(N''[1]'' AS json) AS c FROM dbo.tj'
-- @step batch
SELECT id, j INTO dbo.tj_into FROM dbo.tj; SELECT c.name, TYPE_NAME(c.system_type_id) AS t, c.max_length FROM sys.columns c WHERE c.object_id = OBJECT_ID('dbo.tj_into') ORDER BY c.column_id
-- @step batch
DECLARE @t TABLE (j json); INSERT @t VALUES (N'{ "a" : 1 }'); SELECT j FROM @t
-- @step batch
CREATE TABLE #t (j json); INSERT #t VALUES (N'[ 1 ]'); SELECT j FROM #t
-- @step batch
ALTER TABLE dbo.tj_into ADD x json NULL; SELECT c.name, TYPE_NAME(c.system_type_id) AS t FROM sys.columns c WHERE c.object_id = OBJECT_ID('dbo.tj_into') ORDER BY c.column_id
-- @step batch
CREATE TABLE dbo.s3 (id int, n nvarchar(max)); INSERT dbo.s3 VALUES (1, N'{ "a" : 1 }'); ALTER TABLE dbo.s3 ALTER COLUMN n json; SELECT n FROM dbo.s3
-- @step batch
CREATE TABLE dbo.s4 (id int, n nvarchar(max)); INSERT dbo.s4 VALUES (1, N'nope'); ALTER TABLE dbo.s4 ALTER COLUMN n json; SELECT n FROM dbo.s4
-- @step batch
SELECT TYPE_NAME(c.system_type_id) AS t FROM sys.columns c WHERE c.object_id = OBJECT_ID('dbo.s4')
-- @step batch
ALTER TABLE dbo.tj_into ALTER COLUMN j nvarchar(max)
-- @step batch
DECLARE @j json = N'{ "a" : [1, 2] }'; SET @j = N'[ 3 ]'; SELECT @j AS j
-- @step batch
DECLARE @j json = N'{"a":1'; SELECT @j AS j
