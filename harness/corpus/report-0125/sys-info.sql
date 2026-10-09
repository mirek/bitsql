-- Volatile instance facts: compare invariants, not machine-specific values.
SELECT CASE WHEN cpu_count>0 THEN 1 ELSE 0 END AS positive_cpu_count,
CASE WHEN physical_memory_kb>0 THEN 1 ELSE 0 END AS positive_memory,
CASE WHEN sqlserver_start_time<=GETDATE() THEN 1 ELSE 0 END AS started,
CASE WHEN scheduler_count>0 THEN 1 ELSE 0 END AS has_scheduler
FROM sys.dm_os_sys_info;
