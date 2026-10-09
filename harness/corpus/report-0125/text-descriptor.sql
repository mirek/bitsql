-- Query text TVF metadata; no live handle is required.
SELECT * FROM sys.dm_exec_sql_text(0x00) WHERE 1=0;
