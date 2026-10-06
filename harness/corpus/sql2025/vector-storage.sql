-- Native vector table storage, metadata, properties and conversion boundaries.
-- @step batch
CREATE TABLE v (id int PRIMARY KEY, x vector(3));
-- @step batch
INSERT INTO v VALUES (1,'[1,2,3]'), (2,NULL);
-- @step batch
SELECT id,x,DATALENGTH(x) AS bytes FROM v ORDER BY id;
-- @step batch
SELECT name,system_type_id,user_type_id,max_length,precision,scale,is_nullable FROM sys.columns WHERE object_id=OBJECT_ID('v') ORDER BY column_id;
-- @step batch
SELECT name,system_type_id,user_type_id,max_length,precision,scale,is_user_defined FROM sys.types WHERE name='vector';
-- @step batch
DECLARE @v vector(3)='[1,2,3]',@s varchar(max); SET @s=@v; SELECT @s AS s;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT CAST(@v AS sql_variant) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT CAST(@v AS json) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT CAST(@v AS vector(2)) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT CAST(@v AS varchar(10)) AS s,CAST(@v AS nvarchar(10)) AS n;
