SELECT 1 AS before_error;
RAISERROR('middle', 16, 2);
SELECT 2 AS after_error
