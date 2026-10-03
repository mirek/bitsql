-- Sequences in sys.objects and OBJECT_ID.
-- @step setup
CREATE SEQUENCE dbo.s AS int START WITH 7 INCREMENT BY 2 MINVALUE 0 MAXVALUE 1000 CYCLE CACHE 10;
-- @step batch
SELECT name, type, type_desc FROM sys.objects WHERE name = 's';
SELECT CASE WHEN OBJECT_ID('dbo.s', 'SO') IS NULL THEN 0 ELSE 1 END AS found;
SELECT name, CAST(start_value AS int) AS start_value, CAST(increment AS int) AS increment, CAST(minimum_value AS int) AS minv, CAST(maximum_value AS int) AS maxv, is_cycling, is_cached, cache_size, CAST(current_value AS int) AS cur, is_exhausted FROM sys.sequences;
