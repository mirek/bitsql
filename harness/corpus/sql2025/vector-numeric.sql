-- Vector floating-point accumulation and textual roundtrip probes.
-- @step batch
DECLARE @a vector(3)='[1,2,3]', @b vector(3)='[0,0,0]'; SELECT VECTOR_NORM(@a,'norm2') AS norm, VECTOR_DISTANCE('euclidean',@a,@b) AS distance, VECTOR_DISTANCE('cosine',@a,@a) AS same, VECTOR_DISTANCE('cosine',@a,@b) AS zero;
-- @step batch
DECLARE @a vector(4)='[1e10,1,-1e10,1]', @b vector(4)='[1,1,1,1]'; SELECT VECTOR_DISTANCE('dot',@a,@b) AS dot,VECTOR_NORM(@a,'norm1') AS n1,VECTOR_NORM(@a,'norm2') AS n2;
-- @step batch
DECLARE @a vector(3)='[1e20,1e20,1e20]'; SELECT VECTOR_NORM(@a,'norm2') AS norm, VECTOR_NORMALIZE(@a,'norm2') AS normalized;
-- @step batch
DECLARE @a vector(3)='[1e-20,1e-20,1e-20]'; SELECT VECTOR_NORM(@a,'norm2') AS norm, VECTOR_NORMALIZE(@a,'norm2') AS normalized;
-- @step batch
DECLARE @a vector(3)='[1.23456789,0.123456789,123456789]'; SELECT @a AS v, CONVERT(varbinary(max),@a) AS binary_data;
