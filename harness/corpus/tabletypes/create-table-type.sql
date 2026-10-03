-- CREATE TYPE ... AS TABLE with PK/UNIQUE/CHECK/DEFAULT/IDENTITY/INDEX:
-- completions, sys.types / sys.table_types rows, TYPE_ID / TYPE_NAME, the
-- type table's sys.columns / sys.indexes rows, and that it is no object.
-- @step batch
CREATE TYPE dbo.IdList AS TABLE (
  id int NOT NULL PRIMARY KEY,
  name nvarchar(20) NULL DEFAULT N'x',
  code char(3) NULL UNIQUE,
  n int IDENTITY(10, 5),
  amount decimal(9, 2) NOT NULL DEFAULT 0,
  CHECK (id > 0),
  INDEX ix_name (name)
);
-- @step batch
CREATE TYPE Names AS TABLE (v nvarchar(50));
CREATE TYPE dbo.Pairs AS TABLE (a int NOT NULL, b int NOT NULL, PRIMARY KEY (a, b));
-- @step batch
SELECT name, system_type_id, user_type_id, schema_id, principal_id, max_length, precision, scale, collation_name, is_nullable, is_user_defined, is_assembly_type, default_object_id, rule_object_id, is_table_type FROM sys.types WHERE is_user_defined = 1 ORDER BY name;
SELECT name, system_type_id, user_type_id, schema_id, principal_id, max_length, precision, scale, collation_name, is_nullable, is_user_defined, is_assembly_type, default_object_id, rule_object_id, is_table_type, is_memory_optimized FROM sys.table_types ORDER BY name;
SELECT TYPE_ID('dbo.IdList'), TYPE_ID('IdList'), TYPE_ID('[dbo].[Names]'), TYPE_ID('dbo.Nope'), TYPE_NAME(TYPE_ID('Pairs'));
SELECT OBJECT_ID('dbo.IdList'), OBJECT_ID('IdList', 'TT');
SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0;
-- @step batch
SELECT c.name, c.column_id, c.system_type_id, c.user_type_id, c.max_length, c.precision, c.scale, c.is_nullable, c.is_identity
FROM sys.columns c JOIN sys.table_types t ON t.type_table_object_id = c.object_id
WHERE t.name = 'IdList' ORDER BY c.column_id;
SELECT i.index_id, i.type_desc, i.is_primary_key, i.is_unique, i.is_unique_constraint
FROM sys.indexes i JOIN sys.table_types t ON t.type_table_object_id = i.object_id
WHERE t.name = 'IdList' ORDER BY i.index_id;
SELECT i.name FROM sys.indexes i JOIN sys.table_types t ON t.type_table_object_id = i.object_id
WHERE t.name = 'IdList' AND i.name = 'ix_name';
-- @step batch
SELECT name, is_table_type FROM sys.types WHERE user_type_id = TYPE_ID('dbo.Pairs');
DROP TYPE dbo.Pairs;
SELECT TYPE_ID('dbo.Pairs');
DROP TYPE IF EXISTS dbo.Pairs;
DROP TYPE IF EXISTS Names;
SELECT name FROM sys.table_types;
