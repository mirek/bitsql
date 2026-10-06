-- Cosine extremes and VECTOR_DISTANCE arity compilation.
-- @step batch
DECLARE @a vector(3)='[1e20,0,0]',@b vector(3)='[-1e20,0,0]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1e20,0,0]',@b vector(3)='[0,1e20,0]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1e20,0,0]',@b vector(3)='[1,0,0]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1e20,0,0]',@b vector(3)='[0,0,0]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1e-30,0,0]',@b vector(3)='[1e20,0,0]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS d;
-- @step batch
DECLARE @a vector(3)='[1e20,1e20,0]',@b vector(3)='[1e20,-1e20,0]'; SELECT VECTOR_DISTANCE('cosine',@a,@b) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('dot',@v) AS d;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_DISTANCE('dot',@v,@v,0,1) AS d;
