-- Migration-script catalog probes: OBJECT_ID / COL_LENGTH / INDEXPROPERTY
-- guards around DDL (second runs are no-ops), plus INFORMATION_SCHEMA checks.
-- @step batch
IF OBJECT_ID('dbo.users', 'U') IS NULL
  CREATE TABLE dbo.users (id int IDENTITY(1,1) NOT NULL CONSTRAINT pk_users PRIMARY KEY, email nvarchar(200) NOT NULL);
IF OBJECT_ID('dbo.users', 'U') IS NULL
  CREATE TABLE dbo.users (id int NOT NULL);
IF COL_LENGTH('dbo.users', 'created_at') IS NULL
  ALTER TABLE dbo.users ADD created_at datetime2(3) NOT NULL CONSTRAINT df_users_created DEFAULT ('2020-01-01');
IF COL_LENGTH('dbo.users', 'created_at') IS NULL
  ALTER TABLE dbo.users ADD created_at datetime2(3) NULL;
IF OBJECT_ID('dbo.users_email', 'UQ') IS NULL
  ALTER TABLE dbo.users ADD CONSTRAINT users_email UNIQUE (email);
IF INDEXPROPERTY(OBJECT_ID('dbo.users'), 'ix_users_created', 'IndexID') IS NULL
  CREATE INDEX ix_users_created ON dbo.users (created_at DESC);
IF INDEXPROPERTY(OBJECT_ID('dbo.users'), 'ix_users_created', 'IndexID') IS NULL
  CREATE INDEX ix_users_created ON dbo.users (created_at DESC);
INSERT INTO dbo.users (email) VALUES (N'a@example.com');
SELECT id, email, created_at FROM dbo.users;
-- @step batch
SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'users';
SELECT COLUMN_NAME, ORDINAL_POSITION, COLUMN_DEFAULT, IS_NULLABLE, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, CHARACTER_OCTET_LENGTH, NUMERIC_PRECISION, NUMERIC_PRECISION_RADIX, NUMERIC_SCALE, DATETIME_PRECISION, CHARACTER_SET_NAME, COLLATION_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'users' ORDER BY ORDINAL_POSITION;
SELECT CONSTRAINT_NAME, CONSTRAINT_TYPE FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE TABLE_NAME = 'users' ORDER BY CONSTRAINT_NAME;
SELECT c.name, c.column_id, c.is_nullable FROM sys.columns AS c WHERE c.object_id = OBJECT_ID('dbo.users') AND c.name = 'email';
SELECT COL_LENGTH('dbo.users', 'email') AS email_len, COL_LENGTH('users', 'nosuch') AS missing, COLUMNPROPERTY(OBJECT_ID('dbo.users'), 'id', 'IsIdentity') AS ident;
-- @step batch
IF OBJECT_ID('dbo.v_users', 'V') IS NOT NULL DROP VIEW dbo.v_users;
DROP TABLE IF EXISTS dbo.nosuch;
DROP INDEX IF EXISTS ix_nosuch ON dbo.users;
ALTER TABLE dbo.users DROP CONSTRAINT IF EXISTS ck_nosuch;
ALTER TABLE dbo.users DROP COLUMN IF EXISTS nosuch;
