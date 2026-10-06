-- Vector norm SIMD boundary at overflow and underflow magnitudes.
-- @step batch
DECLARE @v vector(7)='[1e20,1e20,1e20,1e20,1e20,1e20,1e20]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
-- @step batch
DECLARE @v vector(7)='[1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
-- @step batch
DECLARE @v vector(7)='[3e38,3e38,3e38,3e38,3e38,3e38,3e38]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
-- @step batch
DECLARE @v vector(8)='[1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
-- @step batch
DECLARE @v vector(8)='[1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
-- @step batch
DECLARE @v vector(8)='[3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
-- @step batch
DECLARE @v vector(9)='[1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
-- @step batch
DECLARE @v vector(9)='[1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
-- @step batch
DECLARE @v vector(9)='[3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
-- @step batch
DECLARE @v vector(16)='[1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20,1e20]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
-- @step batch
DECLARE @v vector(16)='[1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30,1e-30]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
-- @step batch
DECLARE @v vector(16)='[3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38,3e38]'; SELECT VECTOR_NORM(@v,'norm2') AS n2, VECTOR_NORMALIZE(@v,'norm2') AS v2, VECTOR_NORMALIZE(@v,'norm1') AS v1;
