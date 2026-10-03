-- sys.sequences: sql_variant columns of the sequence's type, current_value
-- (the start value until first use), is_exhausted, last_used_value,
-- cache_size (NULL unless CACHE n).
-- @step setup
CREATE SEQUENCE dbo.s1 AS int START WITH 7 INCREMENT BY 2 MINVALUE 0 MAXVALUE 11 CACHE 2;
CREATE SEQUENCE dbo.s2;
CREATE SEQUENCE dbo.s3 AS decimal(5,0) START WITH 10 INCREMENT BY -1 NO CACHE;
CREATE SEQUENCE dbo.s4 AS tinyint CYCLE;
-- @step batch
SELECT name, type, type_desc, principal_id, start_value, increment, minimum_value, maximum_value, is_cycling, is_cached,
       cache_size, system_type_id, user_type_id, precision, scale, current_value, is_exhausted, last_used_value,
       is_ms_shipped, SQL_VARIANT_PROPERTY(start_value, 'BaseType') AS bt, SQL_VARIANT_PROPERTY(current_value, 'BaseType') AS cbt
FROM sys.sequences ORDER BY name;
-- @step batch
SELECT NEXT VALUE FOR dbo.s1 AS a;
SELECT NEXT VALUE FOR dbo.s1 AS b;
SELECT name, current_value, is_exhausted, last_used_value FROM sys.sequences WHERE name = 's1';
SELECT NEXT VALUE FOR dbo.s1 AS c;
SELECT name, current_value, is_exhausted, last_used_value FROM sys.sequences WHERE name = 's1';
-- @step batch
SELECT NEXT VALUE FOR dbo.s1 AS d;
-- @step batch
SELECT name, current_value, is_exhausted, last_used_value FROM sys.sequences WHERE name = 's1';
ALTER SEQUENCE dbo.s1 RESTART;
SELECT name, current_value, is_exhausted, last_used_value FROM sys.sequences WHERE name = 's1';
ALTER SEQUENCE dbo.s2 CACHE 5;
SELECT name, is_cached, cache_size FROM sys.sequences WHERE name = 's2';
SELECT NEXT VALUE FOR dbo.s3 AS e;
SELECT name, current_value, is_exhausted, last_used_value FROM sys.sequences WHERE name = 's3';
