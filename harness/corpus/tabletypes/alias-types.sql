-- Alias types (CREATE TYPE ... FROM base [NULL|NOT NULL]): columns,
-- variables and parameters of the type, NOT NULL default, sys.types and
-- sys.columns user_type_id, CAST to an alias (243), DROP while in use (3732).
-- @step batch
CREATE TYPE dbo.Email FROM nvarchar(256) NOT NULL;
CREATE TYPE Amount FROM decimal(12, 3);
CREATE TYPE dbo.Flag FROM bit NULL;
CREATE TYPE dbo.Code FROM varchar(5);
-- @step batch
SELECT name, system_type_id, user_type_id, schema_id, principal_id, max_length, precision, scale, collation_name, is_nullable, is_user_defined, is_assembly_type, default_object_id, rule_object_id, is_table_type FROM sys.types WHERE is_user_defined = 1 ORDER BY user_type_id;
SELECT TYPE_ID('Email'), TYPE_NAME(TYPE_ID('dbo.Amount')), TYPE_ID('dbo.Code');
-- @step batch
CREATE TABLE dbo.users (id int NOT NULL, e dbo.Email, a Amount, f dbo.Flag, c dbo.Code NULL, e2 Email NULL);
SELECT name, system_type_id, user_type_id, max_length, precision, scale, is_nullable FROM sys.columns WHERE object_id = OBJECT_ID('dbo.users') ORDER BY column_id;
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, NUMERIC_PRECISION, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'users' ORDER BY ORDINAL_POSITION;
-- @step batch
INSERT INTO dbo.users (id, e, a) VALUES (1, N'a@b', 1.2345);
INSERT INTO dbo.users (id, a) VALUES (2, 3);
SELECT * FROM dbo.users;
-- @step batch
DECLARE @e dbo.Email = N'x@y', @a Amount = 2.5, @c dbo.Code = 'abcdefg';
SELECT @e AS e, @a AS a, @c AS c, SQL_VARIANT_PROPERTY(@a, 'BaseType') AS bt, SQL_VARIANT_PROPERTY(@a, 'Scale') AS sc;
DECLARE @n dbo.Email;
SELECT @n AS n;
-- @step batch
CREATE PROCEDURE dbo.p @e dbo.Email, @a Amount = 1 AS SELECT @e AS e, @a AS a;
-- @step batch
EXEC dbo.p N'q';
EXEC dbo.p @e = NULL, @a = 7.0005;
-- @step batch
SELECT CAST(1 AS Amount);
-- @step batch
DROP TYPE dbo.Email;
-- @step batch
DROP TYPE dbo.Flag;
SELECT name FROM sys.types WHERE is_user_defined = 1 ORDER BY name;
-- @step batch
CREATE TYPE dbo.Bad FROM nvarchar(5000);
-- @step batch
CREATE TYPE dbo.Bad2 FROM dbo.Email;
