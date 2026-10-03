-- Trap: arithmetic overflow on decimal conversion is error 8115, not silent rounding.
SELECT CAST(123.45 AS decimal(4,2)) AS overflow;
