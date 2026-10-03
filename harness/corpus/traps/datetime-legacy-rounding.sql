-- Trap: legacy datetime rounds to 1/300 s (.000, .003, .007).
SELECT CAST('2024-01-01T00:00:00.001' AS datetime) AS ms001,
       CAST('2024-01-01T00:00:00.002' AS datetime) AS ms002,
       CAST('2024-01-01T00:00:00.005' AS datetime) AS ms005,
       CAST('2024-01-01T00:00:00.009' AS datetime) AS ms009,
       CAST('2024-01-01T23:59:59.999' AS datetime) AS ms999,
       CONVERT(varchar(30), CAST('2024-01-01T00:00:00.005' AS datetime), 121) AS ms005_text,
       CASE WHEN CAST('2024-01-01T00:00:00.002' AS datetime) = CAST('2024-01-01T00:00:00.003' AS datetime) THEN 1 ELSE 0 END AS rounded_eq;
