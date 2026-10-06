-- Initial vector-index contract capture against the pinned SQL Server oracle.
-- @step setup
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
CREATE TABLE t(id int CONSTRAINT PK_vector_probe PRIMARY KEY, v vector(3));
INSERT t VALUES(1,'[1,0,0]'),(2,'[1,1,0]'),(3,'[0,1,0]');
-- @step batch
CREATE VECTOR INDEX vi ON t(v) WITH(METRIC='cosine',TYPE='diskann');
-- @step batch
SELECT name,type,type_desc FROM sys.indexes WHERE object_id=OBJECT_ID('t') ORDER BY index_id;
SELECT name,vector_index_type,distance_metric,build_parameters FROM sys.vector_indexes WHERE object_id=OBJECT_ID('t');
-- @step batch
DECLARE @q vector(3)='[1,0,0]'; SELECT id,distance FROM VECTOR_SEARCH(TABLE=t AS s,COLUMN=v,SIMILAR_TO=@q,METRIC='cosine',TOP_N=2) ORDER BY distance,id;
-- @step batch
DECLARE @q vector(3)='[1,0,0]'; SELECT TOP(2) WITH APPROXIMATE id,distance FROM VECTOR_SEARCH(TABLE=t AS s,COLUMN=v,SIMILAR_TO=@q,METRIC='cosine') ORDER BY distance,id;
-- @step batch
INSERT t VALUES(4,'[1,1,0]'); SELECT COUNT(*) AS n FROM t;
