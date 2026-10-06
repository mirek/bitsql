-- Oracle probes for native vectors and scalar vector operations.
-- @step batch
DECLARE @v vector(3) = '[1,2,3]'; SELECT @v AS v, CAST(@v AS varchar(max)) AS text, DATALENGTH(@v) AS bytes;
-- @step batch
DECLARE @v vector(3) = '[3,4,0]'; SELECT VECTOR_NORM(@v, 'norm2') AS norm, VECTOR_NORMALIZE(@v, 'norm2') AS unit;
-- @step batch
DECLARE @a vector(3) = '[1,0,0]', @b vector(3) = '[0,1,0]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS cosine, VECTOR_DISTANCE('dot',@a,@b) AS dot, VECTOR_DISTANCE('euclidean',@a,@b) AS euclidean;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]'; SELECT VECTORPROPERTY(@v, 'Dimensions') AS dimensions, VECTORPROPERTY(@v, 'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3) = '[1,2]'; SELECT @v;
-- @step batch
DECLARE @v vector(3) = '[1,null,3]'; SELECT @v;
-- @step batch
DECLARE @v vector(0);
-- @step batch
DECLARE @v vector(3) = '[0,0,0]'; SELECT VECTOR_NORMALIZE(@v, 'norm2') AS unit;
-- @step batch
DECLARE @a vector(2) = '[1,0]', @b vector(3) = '[0,1,0]'; SELECT VECTOR_DISTANCE('euclidean',@a,@b);
-- @step batch
DECLARE @v vector(3) = '[1,2,3]'; SELECT VECTOR_NORM(@v,'bad');
