-- Vector function arity and argument typing.
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORM() AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORM(NULL) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORM(NULL,NULL) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORM('[1,2,3]','norm2') AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORM(1,'norm2') AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORM(@v,1) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORM(@v,NULL) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORM(@v,'x','y') AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORMALIZE() AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORMALIZE(NULL) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORMALIZE(NULL,NULL) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORMALIZE('[1,2,3]','norm2') AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORMALIZE(1,'norm2') AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORMALIZE(@v,1) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORMALIZE(@v,NULL) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORMALIZE(@v,'x','y') AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTORPROPERTY() AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTORPROPERTY(NULL) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTORPROPERTY(NULL,NULL) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTORPROPERTY('[1,2,3]','norm2') AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTORPROPERTY(1,'norm2') AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTORPROPERTY(@v,1) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTORPROPERTY(@v,NULL) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTORPROPERTY(@v,'x','y') AS v;
