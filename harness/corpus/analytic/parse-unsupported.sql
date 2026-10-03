-- PARSE / TRY_PARSE inputs bitsql does not model raise an emulator error
-- (50171 culture, 50172 date/time format); the oracle's real answers are
-- kept so the gap stays visible. No clock-dependent input is used.
-- @step batch
SELECT TRY_PARSE('1.234,5' AS decimal(10,2) USING 'de-DE') a;
-- @step batch
SELECT TRY_PARSE('15/01/2024' AS date USING 'en-GB') a;
-- @step batch
SELECT TRY_PARSE('2024-01-15T13:45:30Z' AS datetime2) a;
-- @step batch
SELECT TRY_PARSE('Mon, 15 Jan 2024 10:00:00 GMT' AS datetime2) a;
-- @step batch
SELECT TRY_PARSE('Sept 15 2024' AS date) a;
