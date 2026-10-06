-- SQL Server 2025 feature audit: vector.
-- @step batch
DECLARE @a vector(3) = '[1,0,0]', @b vector(3) = '[0,1,0]'; SELECT VECTOR_DISTANCE('euclidean', @a, @b) AS distance;
