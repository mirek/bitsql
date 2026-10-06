-- Native vector maximum dimensions and long TDS JSON fallback values.
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
DECLARE @v vector(1998,float32)='['+REPLICATE('1,',1997)+'1]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('euclidean',@v,@v) AS euclidean,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(1999,float16)='['+REPLICATE('1,',1998)+'1]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('euclidean',@v,@v) AS euclidean,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(3996,float16)='['+REPLICATE('1,',3995)+'1]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('euclidean',@v,@v) AS euclidean,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
