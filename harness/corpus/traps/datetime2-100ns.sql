-- Trap: datetime2/datetimeoffset carry 100 ns ticks; a millisecond clock breaks comparisons.
SELECT CAST('2024-01-01T00:00:00.1234567' AS datetime2(7)) AS dt2,
       CASE WHEN CAST('2024-01-01T00:00:00.1234567' AS datetime2(7)) = CAST('2024-01-01T00:00:00.1234568' AS datetime2(7)) THEN 1 ELSE 0 END AS same_ms_eq,
       CASE WHEN CAST('2024-01-01T00:00:00.1234567' AS datetime2(7)) < CAST('2024-01-01T00:00:00.1234568' AS datetime2(7)) THEN 1 ELSE 0 END AS tick_lt,
       DATEDIFF_BIG(nanosecond, CAST('2024-01-01T00:00:00.1234567' AS datetime2(7)), CAST('2024-01-01T00:00:00.1234568' AS datetime2(7))) AS ns_diff,
       CAST('2024-01-01T00:00:00.1234567+05:30' AS datetimeoffset(7)) AS dto,
       CONVERT(nvarchar(40), CAST('2024-01-01T00:00:00.1234567+05:30' AS datetimeoffset(7)), 127) AS dto_text,
       CAST('2024-01-01T00:00:00.1234567' AS datetime2(3)) AS rounded3,
       CONVERT(varchar(40), CAST('2024-01-01T23:59:59.9999999' AS datetime2(7)), 126) AS max_text,
       CAST(CAST('2024-01-01T23:59:59.9999999' AS datetime2(7)) AS datetime2(6)) AS rounds_to_next_day;
