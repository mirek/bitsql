-- Float16 error precedence, typed NULLs and catalog descriptions.
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
DECLARE @v vector(2,float16)='[1,2]'; SELECT CAST(@v AS vector(3,float32));
-- @step batch
DECLARE @v vector(2,float32)='[1,2]'; SELECT CAST(@v AS vector(3,float16));
-- @step batch
DECLARE @a vector(2,float16)='[1,2]',@b vector(3,float32)='[1,2,3]'; SELECT VECTOR_DISTANCE('dot',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3,float16)='[1,2,3]',@b vector(3,float32)='[1,2,3]'; SELECT VECTOR_DISTANCE('bad',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3,float16),@b vector(3,float32)='[1,2,3]'; SELECT VECTOR_DISTANCE('bad',@a,@b) AS d;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT VECTOR_NORM(@v,1) AS n;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT VECTOR_NORMALIZE(@v,1) AS n;
-- @step batch
DECLARE @v vector(3,float16); SELECT TRY_CAST(@v AS vector(3,float32)) AS v;
-- @step batch
DECLARE @v sys.vector(3,float16)='[1,2,3]'; SELECT @v AS v,CAST(@v AS json) AS j;
-- @step batch
CREATE TABLE vhalf(id int,h vector(3,float16)); INSERT vhalf VALUES(1,'[1,2,3]');
-- @step batch
SELECT COLUMN_NAME,DATA_TYPE,CHARACTER_MAXIMUM_LENGTH,CHARACTER_OCTET_LENGTH,NUMERIC_PRECISION,NUMERIC_SCALE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='vhalf' ORDER BY ORDINAL_POSITION;
-- @step batch
EXEC sys.sp_describe_first_result_set N'SELECT h FROM vhalf';
