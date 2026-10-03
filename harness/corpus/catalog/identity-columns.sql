-- sys.identity_columns has sql_variant columns (seed_value, increment_value,
-- last_value) the emulator does not model: stays an explicit gap.
CREATE TABLE dbo.ic (id int IDENTITY(5, 2) NOT NULL, v int NULL);
SELECT name, CAST(seed_value AS int) AS seed, CAST(increment_value AS int) AS incr FROM sys.identity_columns WHERE object_id = OBJECT_ID('dbo.ic');
