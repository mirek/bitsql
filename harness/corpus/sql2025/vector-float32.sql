-- Explicit float32 descriptors in variables, casts and table columns.
-- @step batch
DECLARE @v vector(3,float32)='[1,2,3]'; SELECT @v AS v,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,FLOAT32)='[1,2,3]'; SELECT @v AS v;
-- @step batch
SELECT CAST('[1,2,3]' AS vector(3,float32)) AS v;
-- @step batch
CREATE TABLE vf32 (id int, v vector(3,float32));
INSERT vf32 VALUES (1,'[1,2,3]'),(2,NULL);
SELECT id,v,DATALENGTH(v) AS bytes FROM vf32 ORDER BY id;
