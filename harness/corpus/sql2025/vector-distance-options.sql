-- Fourth VECTOR_DISTANCE argument contract.
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('cosine',@v,@v,0) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('cosine',@v,@v,1) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('cosine',@v,@v,2) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('cosine',@v,@v,-1) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('cosine',@v,@v,NULL) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('cosine',@v,@v,'x') AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('cosine',@v,@v,'normalized') AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('cosine',@v,@v,CAST(1 AS bit)) AS d;
