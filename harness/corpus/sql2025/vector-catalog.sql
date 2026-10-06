-- Vector catalog descriptors and stored procedures.
-- @step batch
CREATE TABLE v (id int PRIMARY KEY,x vector(3));
-- @step batch
EXEC sp_columns 'v';
-- @step batch
SELECT DATA_TYPE,CHARACTER_MAXIMUM_LENGTH,CHARACTER_OCTET_LENGTH,NUMERIC_PRECISION,NUMERIC_SCALE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='v' AND COLUMN_NAME='x';
-- @step batch
EXEC sp_describe_first_result_set N'SELECT x FROM v';
