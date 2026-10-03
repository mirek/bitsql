-- ODBC catalog procedures: sp_columns, sp_tables, sp_pkeys, sp_fkeys
-- (result shapes, internal completions, filters, missing objects).
-- @step setup
CREATE TABLE dbo.parent (id int NOT NULL CONSTRAINT pk_parent PRIMARY KEY, name nvarchar(50) NULL);
CREATE TABLE dbo.child (cid int IDENTITY(1,1) NOT NULL CONSTRAINT pk_child PRIMARY KEY, pid int NOT NULL CONSTRAINT fk_child_parent REFERENCES dbo.parent(id), amount decimal(10,2) NULL CONSTRAINT df_amount DEFAULT 0);
CREATE TABLE dbo.kinds (a bigint NOT NULL, b varchar(10), c nvarchar(max), d bit, e datetime2(3), f uniqueidentifier, g float, h date, i char(2), j varbinary(16), k tinyint, l smallint, m money, n datetime, o time(7), CONSTRAINT pk_kinds PRIMARY KEY (a, k));
-- @step setup
CREATE TABLE dbo.kinds2 (a smallint NOT NULL, b int NULL, c bigint NULL, d float NOT NULL, e money NOT NULL, f datetime NOT NULL, g real, h smallmoney, i smalldatetime, j datetimeoffset(7), k numeric(5,1), l nchar(3), m binary(4), n varchar(max), o varbinary(max), p sql_variant, q rowversion, r bit NOT NULL, s decimal(4,0) NOT NULL, t uniqueidentifier NOT NULL, u date NOT NULL, v char(1) NOT NULL, w tinyint NULL, x time(0), y datetime2(7), z AS a + 1, aa nvarchar(10) NOT NULL, ab real NOT NULL, ac smallmoney NOT NULL, ad smalldatetime NOT NULL, ae numeric(5,1) NOT NULL, af binary(2) NOT NULL, ag nchar(2) NOT NULL, ah varchar(5) NOT NULL, ai varbinary(5) NOT NULL, aj nvarchar(max) NOT NULL, ak bigint IDENTITY(1,1), al varchar(max) NOT NULL, am float(10));
-- @step setup
CREATE VIEW dbo.v AS SELECT id FROM dbo.parent;
-- @step batch
EXEC sp_columns 'child';
-- @step batch
EXEC sp_columns @table_name = N'kinds';
-- @step batch
EXEC sp_columns @table_name = 'child', @column_name = 'pid';
-- @step batch
EXEC sp_columns 'nothing';
-- @step batch
EXEC sp_tables 'child';
-- @step batch
EXEC sp_tables @table_name = 'v', @table_owner = 'dbo';
-- @step batch
EXEC sp_tables 'nothing';
-- @step batch
EXEC sp_pkeys 'child';
-- @step batch
EXEC sp_pkeys @table_name = N'kinds';
-- @step batch
EXEC sp_pkeys 'v';
-- @step batch
EXEC sp_fkeys 'parent';
-- @step batch
EXEC sp_fkeys @fktable_name = N'child';
-- @step batch
EXEC sp_fkeys 'kinds';
-- @step batch
EXEC sp_columns 'kinds2';
-- @step batch
EXEC sp_columns 'child', 'dbo';
-- @step batch
EXEC sp_columns @table_name = 'nothing', @table_owner = 'dbo';
-- @step batch
EXEC sp_columns 'child', @column_name = 'nothing';
-- @step batch
EXEC sp_tables 'nothing', 'dbo';
-- @step batch
EXEC sp_tables 'child', 'nobody';
-- @step batch
EXEC sp_pkeys 'child', 'dbo';
-- @step batch
EXEC sp_pkeys 'nothing';
-- @step batch
EXEC sp_fkeys 'nothing';
-- @step batch
EXEC sp_fkeys @pktable_name = 'parent', @fktable_name = 'child';
-- @step batch
EXEC sp_fkeys @pktable_name = 'parent', @pktable_owner = 'dbo';
-- @step proc sp_columns
-- @param @table_name nvarchar(384) = "parent"
