-- DATE_BUCKET errors: 9834 width <= 0 and 9835 overflow at run time (after
-- the column metadata); 9810 for dateparts DATE_BUCKET never supports at
-- run time, for parts not fitting date/time at compile time; 155, 1023,
-- 189 and 8116 (argument types, NULL, mismatched origin type).
-- @step batch
SELECT DATE_BUCKET(day, 0, CAST('2024-05-17' AS date));
-- @step batch
SELECT DATE_BUCKET(day, -1, CAST('2024-05-17' AS date));
-- @step batch
SELECT DATE_BUCKET(day, 2147483647, CAST('1800-01-01' AS date)) a;
-- @step batch
SELECT DATE_BUCKET(day, 3, CAST('1753-01-01' AS datetime)) a;
-- @step batch
SELECT DATE_BUCKET(microsecond, 1, CAST('2024-05-17' AS datetime2));
-- @step batch
SELECT DATE_BUCKET(nanosecond, 1, CAST('2024-05-17' AS datetime2)) a;
-- @step batch
SELECT DATE_BUCKET(dayofyear, 1, CAST('2024-05-17' AS datetime2));
-- @step batch
SELECT DATE_BUCKET(weekday, 1, CAST('2024-05-17' AS datetime2));
-- @step batch
SELECT DATE_BUCKET(iso_week, 1, CAST('2024-05-17' AS datetime2)) a;
-- @step batch
SELECT DATE_BUCKET(tzoffset, 1, CAST('2024-05-17' AS datetimeoffset)) a;
-- @step batch
SELECT DATE_BUCKET(hour, 1, CAST('2024-05-17' AS date));
-- @step batch
SELECT DATE_BUCKET(millisecond, 1, CAST('2024-05-17' AS date)) a;
-- @step batch
SELECT DATE_BUCKET(day, 1, CAST('10:00' AS time));
-- @step batch
SELECT DATE_BUCKET(month, 1, CAST('10:00' AS time)) a;
-- @step batch
SELECT DATE_BUCKET(xx, 1, CAST('2024-05-17' AS date)) a;
-- @step batch
SELECT DATE_BUCKET('day', 1, CAST('2024-05-17' AS date)) a;
-- @step batch
SELECT DATE_BUCKET(day, 1) a;
-- @step batch
SELECT DATE_BUCKET(day, 1, CAST('2024-05-17' AS date), CAST('2024-05-17' AS date), 1) a;
-- @step batch
SELECT DATE_BUCKET(day, 1, '2024-05-17');
-- @step batch
SELECT DATE_BUCKET(day, 2, 5);
-- @step batch
SELECT DATE_BUCKET(day, '2', CAST('2024-05-17' AS date)) a;
-- @step batch
SELECT DATE_BUCKET(day, NULL, CAST('2024-05-17' AS date)) a;
-- @step batch
SELECT DATE_BUCKET(day, 1, NULL) a;
-- @step batch
SELECT DATE_BUCKET(day, 1, CAST('2024-05-17' AS date), CAST('2024-01-01 10:00' AS datetime2));
-- @step batch
SELECT DATE_BUCKET(day, 1, CAST('2024-05-17' AS datetime2), CAST('2024-01-01' AS date));
-- @step batch
SELECT DATE_BUCKET(day, 1, CAST('2024-05-17' AS datetime), CAST('2024-01-01' AS smalldatetime)) a;
-- @step batch
SELECT DATE_BUCKET(day, 1, CAST('2024-05-17' AS datetime2), '2024-01-01') a;
-- @step batch
SELECT DATE_BUCKET(year, 200000000, CAST('2024-05-17' AS date)) a;
-- @step batch
SELECT DATE_BUCKET(year, 100, CAST('1800-01-01' AS date)) a, DATE_BUCKET(year, 1000, CAST('1800-01-01' AS date)) b;
-- @step batch
SELECT DATE_BUCKET(year, 178956970, CAST('1800-01-01' AS date)) a;
-- @step batch
SELECT DATE_BUCKET(day, 1000000, CAST('1800-01-01' AS date)) c;
