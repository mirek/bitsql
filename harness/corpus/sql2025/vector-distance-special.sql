-- Distance NULL/type controls, zero vectors, extremes and exact fused rounding.
-- @step batch
DECLARE @a vector(3)='[0,0,0]',@b vector(3)='[0,0,0]'; SELECT VECTOR_DISTANCE('dot',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[0,0,0]',@b vector(3)='[0,0,0]'; SELECT VECTOR_DISTANCE('euclidean',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[0,0,0]',@b vector(3)='[0,0,0]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1,2,3]',@b vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('dot',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1,2,3]',@b vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('euclidean',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1,2,3]',@b vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1,2,3]',@b vector(3)='[-1,-2,-3]'; SELECT VECTOR_DISTANCE('dot',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1,2,3]',@b vector(3)='[-1,-2,-3]'; SELECT VECTOR_DISTANCE('euclidean',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1,2,3]',@b vector(3)='[-1,-2,-3]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1e-30,0,0]',@b vector(3)='[1e-30,0,0]'; SELECT VECTOR_DISTANCE('dot',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1e-30,0,0]',@b vector(3)='[1e-30,0,0]'; SELECT VECTOR_DISTANCE('euclidean',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1e-30,0,0]',@b vector(3)='[1e-30,0,0]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1e20,0,0]',@b vector(3)='[1e20,0,0]'; SELECT VECTOR_DISTANCE('dot',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1e20,0,0]',@b vector(3)='[1e20,0,0]'; SELECT VECTOR_DISTANCE('euclidean',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1e20,0,0]',@b vector(3)='[1e20,0,0]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE() AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('dot') AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('dot',NULL,NULL) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE(NULL,@v,@v) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE(1,@v,@v) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('dot','[1,2,3]',@v) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('dot',@v,1) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('bad',NULL,@v) AS d;
-- @step batch
DECLARE @a vector(9)='[-8.271806125530277e-25, 0, 0, 0, 0, 0, 0, 0, 1.0000001192092896]',@b vector(9)='[1, 0, 0, 0, 0, 0, 0, 0, 1.5]'; SELECT VECTOR_DISTANCE('dot',@a,@b) AS d;
-- @step batch
DECLARE @a vector(9)='[8.271806125530277e-25, 0, 0, 0, 0, 0, 0, 0, 1.0000003576278687]',@b vector(9)='[1, 0, 0, 0, 0, 0, 0, 0, 1.5]'; SELECT VECTOR_DISTANCE('dot',@a,@b) AS d;
-- @step batch
DECLARE @a vector(9)='[-1.0, 0, 0, 0, 0, 0, 0, 0, 18631.0]',@b vector(9)='[1, 0, 0, 0, 0, 0, 0, 0, 1.826430984808833e+34]'; SELECT VECTOR_DISTANCE('dot',@a,@b) AS d;
