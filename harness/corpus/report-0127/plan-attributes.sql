-- Plan attributes metadata and dbid variant contract, scoped to our workload.
-- @step batch
SELECT * FROM sys.dm_exec_plan_attributes(0x00);
-- @step batch
SELECT * FROM sys.dm_exec_plan_attributes(NULL);
-- @step batch
SELECT * FROM sys.dm_exec_plan_attributes(CONVERT(varbinary(64),REPLICATE(CHAR(0),64)));
-- @step setup
CREATE TABLE dbo.foo(id int NOT NULL PRIMARY KEY);
INSERT dbo.foo VALUES(1),(2);
-- @step setup
SELECT id AS compatibility_plan_marker FROM dbo.foo;
-- @step batch
SELECT pa.attribute, CASE WHEN CONVERT(int,pa.value)=DB_ID() THEN 1 ELSE 0 END AS matches_database,
SQL_VARIANT_PROPERTY(pa.value,'BaseType') AS base_type,pa.is_cache_key
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) pa
WHERE st.text LIKE N'% AS compatibility_plan_marker%' AND st.text NOT LIKE N'%dm_exec_query_stats%'
AND pa.attribute='dbid';
