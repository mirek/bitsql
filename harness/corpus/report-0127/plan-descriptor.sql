-- Oracle-derived descriptor; predicate suppresses invalid handle evaluation.
SELECT * FROM sys.dm_exec_plan_attributes(0x00) WHERE 1=0;
