-- Extended properties: knex writes column comments with
-- `IF EXISTS(SELECT * FROM sys.fn_listextendedproperty(...)) EXEC
-- sys.sp_updateextendedproperty ... ELSE EXEC sys.sp_addextendedproperty
-- ...`, Sequelize's describeTable LEFT JOINs sys.extended_properties.
-- The procedures are T-SQL inside SQL Server: their token streams
-- (internal DONEINPROCs, BEGIN/ROLLBACK ENVCHANGEs) and request row counts
-- are masked; results, errors and their lines are compared.
-- @step setup
CREATE TABLE t (id int NOT NULL PRIMARY KEY, code varchar(10) NULL, n int NULL);
-- @step setup
CREATE VIEW v AS SELECT id, code FROM t;
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sys.sp_addextendedproperty N'MS_Description', N'short code', N'Schema', N'dbo', N'Table', N't', N'Column', N'code';
EXEC sp_addextendedproperty @name = N'MS_Description', @value = N'the table', @level0type = N'SCHEMA', @level0name = 'dbo', @level1type = N'TABLE', @level1name = 't';
EXEC sp_addextendedproperty N'num', 42, N'Schema', N'dbo', N'Table', N't', N'Column', N'n';
EXEC sp_addextendedproperty N'x', N'on view', N'Schema', N'dbo', N'View', N'v';
EXEC sp_addextendedproperty N'x', N'on view col', N'Schema', N'dbo', N'View', N'v', N'Column', N'id';
EXEC sp_addextendedproperty N'schemaprop', N'sp', N'Schema', N'dbo';
EXEC sp_addextendedproperty N'nullvalue', NULL, N'Schema', N'dbo', N'Table', N't';
SELECT class, class_desc, CASE WHEN class = 1 THEN OBJECT_NAME(major_id) ELSE SCHEMA_NAME(major_id) END AS obj, minor_id, name, value,
  SQL_VARIANT_PROPERTY(value, 'BaseType') AS bt, SQL_VARIANT_PROPERTY(value, 'MaxLength') AS ml
FROM sys.extended_properties ORDER BY class, obj, minor_id, name;
-- @step batch
SELECT * FROM sys.fn_listextendedproperty(N'MS_Description', N'Schema', N'dbo', N'Table', N't', N'Column', N'code');
SELECT * FROM sys.fn_listextendedproperty(NULL, N'schema', N'dbo', N'table', N't', N'column', NULL) ORDER BY objname;
SELECT * FROM sys.fn_listextendedproperty(NULL, N'schema', N'dbo', N'table', NULL, NULL, NULL) ORDER BY name;
SELECT * FROM sys.fn_listextendedproperty(NULL, N'schema', N'dbo', N'table', N't', NULL, NULL) ORDER BY name;
SELECT * FROM sys.fn_listextendedproperty(NULL, N'schema', N'dbo', N'view', NULL, NULL, NULL);
SELECT * FROM sys.fn_listextendedproperty(NULL, N'schema', N'dbo', N'view', N'v', N'column', NULL);
SELECT * FROM sys.fn_listextendedproperty(NULL, N'schema', NULL, NULL, NULL, NULL, NULL);
SELECT * FROM sys.fn_listextendedproperty(NULL, NULL, NULL, NULL, NULL, NULL, NULL);
SELECT * FROM sys.fn_listextendedproperty(N'nope', N'schema', N'dbo', N'table', N't', NULL, NULL);
SELECT * FROM sys.fn_listextendedproperty(N'ms_description', N'SCHEMA', N'DBO', N'TABLE', N'T', NULL, NULL);
SELECT * FROM sys.fn_listextendedproperty('default', N'schema', N'dbo', N'table', N't', N'column', 'default') ORDER BY objname;
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
IF EXISTS(SELECT * FROM sys.fn_listextendedproperty(N'MS_Description', N'Schema', N'dbo', N'Table', N't', N'Column', N'code'))
  EXEC sys.sp_updateextendedproperty N'MS_Description', N'new code', N'Schema', N'dbo', N'Table', N't', N'Column', N'code'
ELSE EXEC sys.sp_addextendedproperty N'MS_Description', N'new code', N'Schema', N'dbo', N'Table', N't', N'Column', N'code';
SELECT name, value FROM sys.extended_properties WHERE major_id = OBJECT_ID('t') AND minor_id > 0 ORDER BY minor_id;
-- Sequelize describeTable (sequelize 6.37.8 lib/dialects/mssql/query-generator.js)
-- @step batch
SELECT c.COLUMN_NAME AS 'Name', c.DATA_TYPE AS 'Type', c.CHARACTER_MAXIMUM_LENGTH AS 'Length', c.IS_NULLABLE as 'IsNull', COLUMN_DEFAULT AS 'Default', pk.CONSTRAINT_TYPE AS 'Constraint', COLUMNPROPERTY(OBJECT_ID('[' + c.TABLE_SCHEMA + '].[' + c.TABLE_NAME + ']'), c.COLUMN_NAME, 'IsIdentity') as 'IsIdentity', CAST(prop.value AS NVARCHAR) AS 'Comment' FROM INFORMATION_SCHEMA.TABLES t INNER JOIN INFORMATION_SCHEMA.COLUMNS c ON t.TABLE_NAME = c.TABLE_NAME AND t.TABLE_SCHEMA = c.TABLE_SCHEMA LEFT JOIN (SELECT tc.table_schema, tc.table_name, cu.column_name, tc.CONSTRAINT_TYPE FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE cu ON tc.table_schema=cu.table_schema and tc.table_name=cu.table_name and tc.constraint_name=cu.constraint_name and tc.CONSTRAINT_TYPE='PRIMARY KEY') pk ON pk.table_schema=c.table_schema AND pk.table_name=c.table_name AND pk.column_name=c.column_name INNER JOIN sys.columns AS sc ON sc.object_id = OBJECT_ID('[' + t.TABLE_SCHEMA + '].[' + t.TABLE_NAME + ']') AND sc.name = c.column_name LEFT JOIN sys.extended_properties prop ON prop.major_id = sc.object_id AND prop.minor_id = sc.column_id AND prop.name = 'MS_Description' WHERE t.TABLE_NAME = 't' ORDER BY c.ORDINAL_POSITION;
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty N'MS_Description', N'dup', N'Schema', N'dbo', N'Table', N't', N'Column', N'code';
SELECT 1 AS not_reached;
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_updateextendedproperty N'missing', N'x', N'Schema', N'dbo', N'Table', N't', N'Column', N'code';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_dropextendedproperty N'missing', N'Schema', N'dbo', N'Table', N't';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty N'MS_Description', N'x', N'Schema', N'dbo', N'Table', N'nope';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_updateextendedproperty N'x', N'y', N'Schema', N'dbo', N'Table', N'nope';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_dropextendedproperty N'x', N'Schema', N'dbo', N'Table', N't', N'Column', N'nope';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty N'MS_Description', N'x', N'Schema', N'nope', N'Table', N't';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty N'x', N'y', N'Schema', N'nope';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty N'x', N'y', N'Schema', N'dbo', N'View', N't';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty N'x', N'y', N'Schema', N'dbo', N'Table', N'v';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty N'x', N'y', N'Schema', N'dbo', N'Table', N't', N'Bogus', N'id';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty N'x', N'y', N'Bogus', N'dbo';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty N'x', N'y', N'Schema', N'dbo', N'Table', NULL;
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty N'x', N'y', N'Schema', N'dbo', N'Table', N't', N'Column', NULL;
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty N'x', N'y', NULL, NULL, N'Table', N't';
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
EXEC sp_addextendedproperty NULL, N'y', N'Schema', N'dbo', N'Table', N't';
SELECT 3 AS after_null_name, @@ERROR AS e;
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
BEGIN TRAN;
EXEC sp_addextendedproperty N'MS_Description', N'dup', N'Schema', N'dbo', N'Table', N't';
SELECT 5 AS not_reached;
-- @step batch
SELECT @@TRANCOUNT AS tc;
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
BEGIN TRY
EXEC sp_addextendedproperty N'MS_Description', N'dup', N'Schema', N'dbo', N'Table', N't';
END TRY
BEGIN CATCH
SELECT ERROR_NUMBER() AS n, ERROR_PROCEDURE() AS p, ERROR_LINE() AS l, ERROR_STATE() AS st;
END CATCH
-- @step batch
-- @mask done
-- @mask tokens
-- @mask stream
-- @mask rowCount
DECLARE @r int;
EXEC @r = sp_addextendedproperty N'p2', N'ok', N'Schema', N'dbo', N'Table', N't';
SELECT @r AS r;
EXEC sp_dropextendedproperty N'num', N'Schema', N'dbo', N'Table', N't', N'Column', N'n';
EXEC sp_dropextendedproperty N'schemaprop', N'Schema', N'dbo';
ALTER TABLE t DROP COLUMN n;
SELECT minor_id, name, value FROM sys.extended_properties WHERE class = 1 ORDER BY major_id, minor_id, name;
DROP VIEW v;
DROP TABLE t;
SELECT COUNT(*) AS left_ FROM sys.extended_properties;
