-- Retained allocation across repeated updates, value copies and rollback.
-- @step batch
CREATE TABLE jl(id int PRIMARY KEY,j json);
INSERT jl VALUES(1,N'{"a":{"x":1}}'),(2,N'{"a":"abcdefgh"}');
-- @step batch
-- @mask stream
-- @mask tokens
SET NOCOUNT ON;
DECLARE @i int=0;
WHILE @i<200 BEGIN UPDATE jl SET j=JSON_MODIFY(j,'$.a',JSON_QUERY(j,'$.a')) WHERE id=1; SET @i+=1; END;
SELECT j,DATALENGTH(j) AS bytes FROM jl WHERE id=1;
-- @step batch
-- @mask stream
-- @mask tokens
DECLARE @i int=0;
WHILE @i<2000 BEGIN UPDATE jl SET j=JSON_MODIFY(j,'$.a',JSON_QUERY(j,'$.a')) WHERE id=1; SET @i+=1; END;
SELECT j,DATALENGTH(j) AS bytes FROM jl WHERE id=1;
-- @step batch
UPDATE jl SET j=JSON_MODIFY(j,'$.a','x') WHERE id=2;
DECLARE @source json; SELECT @source=j FROM jl WHERE id=2;
DECLARE @target json=N'{"b":1}';
SELECT DATALENGTH(@source) AS source_bytes,JSON_MODIFY(@target,'$.b',@source) AS j,DATALENGTH(JSON_MODIFY(@target,'$.b',@source)) AS target_bytes;
-- @step batch
DECLARE @original json; SELECT @original=j FROM jl WHERE id=1;
BEGIN TRAN;
UPDATE jl SET j=JSON_MODIFY(j,'$.b',1234567890) WHERE id=1;
SELECT j,DATALENGTH(j) AS bytes,DATALENGTH(@original) AS original_bytes FROM jl WHERE id=1;
ROLLBACK;
SELECT j,DATALENGTH(j) AS bytes FROM jl WHERE id=1;
-- @step batch
DECLARE @original json=N'{"a":1}'; DECLARE @copy json=@original;
SET @copy=JSON_MODIFY(@copy,'$.b',N'new');
SELECT @original AS original,DATALENGTH(@original) AS original_bytes,@copy AS copy,DATALENGTH(@copy) AS copy_bytes;
