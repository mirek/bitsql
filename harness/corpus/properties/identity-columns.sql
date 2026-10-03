-- sys.identity_columns: seed_value, increment_value and last_value are
-- sql_variant of the column's type; last_value is NULL until a row was
-- inserted.
-- @step setup
CREATE TABLE dbo.i1 (id int IDENTITY(5, 2) NOT NULL, v int NULL);
CREATE TABLE dbo.i2 (id bigint IDENTITY(1, 1) NOT NULL, v int NULL);
CREATE TABLE dbo.i3 (id decimal(10,0) IDENTITY(100, 10) NOT NULL, v int NULL);
CREATE TABLE dbo.i4 (id smallint IDENTITY NOT NULL, v int NULL);
CREATE TABLE dbo.i5 (id tinyint IDENTITY(3, 1) NOT NULL, v int NULL);
INSERT INTO dbo.i1 (v) VALUES (1), (2);
INSERT INTO dbo.i3 (v) VALUES (1);
-- @step batch
SELECT OBJECT_NAME(object_id) AS t, name, column_id, system_type_id, user_type_id, max_length, precision, scale,
       collation_name, is_nullable, is_identity, is_computed, seed_value, increment_value, last_value,
       SQL_VARIANT_PROPERTY(seed_value, 'BaseType') AS sbt, SQL_VARIANT_PROPERTY(increment_value, 'BaseType') AS ibt,
       SQL_VARIANT_PROPERTY(last_value, 'BaseType') AS lbt, SQL_VARIANT_PROPERTY(seed_value, 'Precision') AS sp,
       is_not_for_replication, generated_always_type, generated_always_type_desc
FROM sys.identity_columns WHERE OBJECT_NAME(object_id) LIKE 'i_' ORDER BY t;
-- @step batch
INSERT INTO dbo.i2 (v) VALUES (1);
DELETE FROM dbo.i2;
SELECT CAST(last_value AS bigint) AS last_after_delete FROM sys.identity_columns WHERE object_id = OBJECT_ID('dbo.i2');
SELECT c.name, CAST(c.seed_value AS int) AS seed, CAST(c.increment_value AS int) AS incr
FROM sys.identity_columns AS c JOIN sys.tables AS t ON t.object_id = c.object_id WHERE t.name = 'i1';
