-- @step batch
CREATE TABLE t(id int CONSTRAINT pk PRIMARY KEY,j json);
CREATE JSON INDEX ix ON t(j);
-- @step batch
SELECT name,stats_id,auto_created,user_created,no_recompute,has_filter,filter_definition,is_temporary,is_incremental,has_persisted_sample,stats_generation_method,stats_generation_method_desc,auto_drop,replica_role_id,replica_role_desc,replica_name FROM sys.stats WHERE object_id=OBJECT_ID(N't') ORDER BY stats_id;
