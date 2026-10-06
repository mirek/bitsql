-- @step batch
CREATE TABLE t(id int CONSTRAINT pk PRIMARY KEY,j json);
CREATE JSON INDEX ix ON t(j) WITH(OPTIMIZE_FOR_ARRAY_SEARCH=ON);
-- @step batch
SELECT REPLACE(name,CONVERT(nvarchar(20),parent_id),N'<parent>') AS name,type,type_desc,is_ms_shipped,internal_type,internal_type_desc,parent_minor_id,lob_data_space_id,filestream_data_space_id FROM sys.internal_tables WHERE parent_id=OBJECT_ID(N't');
-- @step batch
SELECT c.name,c.column_id,c.system_type_id,c.user_type_id,c.max_length,c.precision,c.scale,c.is_nullable,c.collation_name,c.is_identity FROM sys.columns c JOIN sys.internal_tables t ON t.object_id=c.object_id WHERE t.parent_id=OBJECT_ID(N't') ORDER BY c.column_id;
-- @step batch
SELECT i.index_id,c.name,i.index_column_id,i.key_ordinal,i.is_descending_key,i.is_included_column FROM sys.index_columns i JOIN sys.internal_tables t ON t.object_id=i.object_id JOIN sys.columns c ON c.object_id=i.object_id AND c.column_id=i.column_id WHERE t.parent_id=OBJECT_ID(N't') ORDER BY i.index_id,i.index_column_id;
-- @step batch
SELECT s.name,s.stats_id,s.auto_created,s.user_created,s.no_recompute FROM sys.stats s JOIN sys.internal_tables t ON t.object_id=s.object_id WHERE t.parent_id=OBJECT_ID(N't') ORDER BY s.stats_id;
