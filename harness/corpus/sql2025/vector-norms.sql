-- Vector norms and normalization across rounding and dimension boundaries.
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(3)='[3,4,0]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(3)='[-3,4,0]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(3)='[0,0,0]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(4)='[1e10,1,-1e10,1]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(3)='[1e20,1e20,1e20]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(3)='[1e-20,1e-20,1e-20]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(3)='[1e-45,0,0]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(3)='[1.23456789,0.123456789,123456789]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(1)='[1e10]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(2)='[1e10,0.1]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(7)='[1e10,0.1,-2.7,3,-1e10,0.2,1e-20]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(8)='[1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(9)='[1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(16)='[1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(17)='[1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(32)='[1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(33)='[1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(64)='[1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
-- @step batch
DECLARE @v vector(65)='[1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1,-2.7,3,-1e10,0.2,1e-20,1e10,0.1]'; SELECT VECTOR_NORM(@v,'norm1') AS n0,VECTOR_NORMALIZE(@v,'norm1') AS v0,VECTOR_NORM(@v,'norm2') AS n1,VECTOR_NORMALIZE(@v,'norm2') AS v1,VECTOR_NORM(@v,'norminf') AS n2,VECTOR_NORMALIZE(@v,'norminf') AS v2;
