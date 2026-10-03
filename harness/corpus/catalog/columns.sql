-- sys.columns / sys.computed_columns / sys.types / sys.schemas facts and
-- INFORMATION_SCHEMA.COLUMNS per declared type.
-- @step setup
CREATE TABLE dbo.ty (
  a tinyint NOT NULL, b smallint NULL, c int NULL, d bigint NULL, e bit NULL,
  f decimal(5,2) NULL, g numeric(20,4) NULL, h money NULL, i smallmoney NULL, j float NULL, k real NULL,
  l char(3) NULL, m varchar(20) NULL, n varchar(max) NULL, o nchar(4) NULL, p nvarchar(30) NULL, q nvarchar(max) NULL,
  r binary(8) NULL, s varbinary(16) NULL, t varbinary(max) NULL,
  u date NULL, v time(3) NULL, w datetime2 NULL, x datetime2(0) NULL, y datetimeoffset(4) NULL, z datetime NULL, aa smalldatetime NULL,
  ab uniqueidentifier NULL, ac rowversion, ad nvarchar(10) COLLATE Latin1_General_100_CI_AS NULL,
  ae AS a + 1, af AS c * 2 PERSISTED, ag int IDENTITY(1,1) NOT NULL);
-- @step batch
SELECT name, column_id, system_type_id, user_type_id, max_length, precision, scale, collation_name, is_nullable, is_ansi_padded, is_rowguidcol, is_identity, is_computed, is_filestream, is_sparse, generated_always_type, generated_always_type_desc, is_hidden, is_masked FROM sys.columns WHERE object_id = OBJECT_ID('dbo.ty') ORDER BY column_id;
SELECT column_id, name, definition, is_persisted, uses_database_collation, is_computed FROM sys.computed_columns WHERE object_id = OBJECT_ID('dbo.ty') ORDER BY column_id;
SELECT name, system_type_id, user_type_id, schema_id, principal_id, max_length, precision, scale, collation_name, is_nullable, is_user_defined, is_assembly_type, default_object_id, rule_object_id, is_table_type FROM sys.types ORDER BY user_type_id;
SELECT name, schema_id, principal_id FROM sys.schemas ORDER BY schema_id;
SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, CHARACTER_OCTET_LENGTH, NUMERIC_PRECISION, NUMERIC_PRECISION_RADIX, NUMERIC_SCALE, DATETIME_PRECISION, CHARACTER_SET_NAME, COLLATION_NAME, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'ty' ORDER BY ORDINAL_POSITION;
SELECT COL_LENGTH('dbo.ty', 'p') AS p, COL_LENGTH('dbo.ty', 'q') AS q, COL_LENGTH('dbo.ty', 'f') AS f, COLUMNPROPERTY(OBJECT_ID('dbo.ty'), 'p', 'Precision') AS pp, COLUMNPROPERTY(OBJECT_ID('dbo.ty'), 'f', 'Scale') AS fs, COLUMNPROPERTY(OBJECT_ID('dbo.ty'), 'ae', 'IsComputed') AS comp, COLUMNPROPERTY(OBJECT_ID('dbo.ty'), 'a', 'AllowsNull') AS an, COL_NAME(OBJECT_ID('dbo.ty'), 3) AS c3;
SELECT TYPE_ID('nvarchar') AS a, TYPE_ID('sysname') AS b, TYPE_ID('nosuch') AS c, TYPE_NAME(231) AS d, TYPE_NAME(256) AS e, TYPE_NAME(9999) AS f, SCHEMA_ID('dbo') AS g, SCHEMA_ID('nosuch') AS h, SCHEMA_NAME(1) AS i, SCHEMA_NAME() AS j, DB_NAME(2) AS k, DB_ID('tempdb') AS l, DB_ID('nosuch') AS m;
