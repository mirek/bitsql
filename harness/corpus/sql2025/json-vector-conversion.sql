-- Native JSON returned by AI_GENERATE_EMBEDDINGS must convert to vector.
-- @step batch
SELECT CAST(CAST('[1,2]' AS json) AS vector(2)) AS v;
-- @step batch
DECLARE @j json='[1,2]'; SELECT CAST(@j AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST(NULL AS json) AS vector(2)) AS v;
-- @step batch
DECLARE @j json='[1,2]',@v vector(2); SET @v=@j; SELECT @v AS v;
-- @step batch
SELECT CAST(CAST('{"a":1}' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('[1,null]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('[1,2,3]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT TRY_CAST(CAST('{"a":1}' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('{}' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('[]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('[true,1]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('[false,1]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('["1",2]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('[[1],2]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('[[],2]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('[{},2]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('[{"a":1},2]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT CAST(CAST('[1.25,2.5]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT TRY_CAST(CAST('[1,2,3]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT TRY_CAST(CAST('[1,null]' AS json) AS vector(2)) AS v;
-- @step batch
SELECT TRY_CAST('{"a":1}' AS vector(2)) AS v;
