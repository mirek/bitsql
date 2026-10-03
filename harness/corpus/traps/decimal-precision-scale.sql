-- Trap: decimal result precision/scale rules for * and /, truncation vs rounding.
SELECT CAST(1.5 AS decimal(10,2)) * CAST(2.25 AS decimal(5,3)) AS mul,
       CAST(1 AS decimal(38,10)) * CAST(1 AS decimal(38,10)) AS mul_overflow_scale,
       CAST(10 AS decimal(10,2)) / CAST(3 AS decimal(5,1)) AS div,
       CAST(1 AS decimal(38,0)) / CAST(3 AS decimal(38,0)) AS div_38,
       CAST(10 AS decimal(10,2)) + CAST(1 AS decimal(5,4)) AS add_mixed,
       CAST(2.5 AS int) AS cast_int_truncates, CAST(-2.5 AS int) AS cast_neg_int_truncates,
       CAST(1.005 AS decimal(4,2)) AS cast_decimal_rounds, CAST(-1.005 AS decimal(4,2)) AS cast_neg_decimal_rounds,
       ROUND(2.5, 0) AS round_half, 7 / 2 AS int_div, -7 / 2 AS neg_int_div, -7 % 2 AS neg_mod;
SELECT CAST(SQL_VARIANT_PROPERTY(CAST(1.5 AS decimal(10,2)) * CAST(2.25 AS decimal(5,3)), 'Precision') AS int) AS mul_p,
       CAST(SQL_VARIANT_PROPERTY(CAST(1.5 AS decimal(10,2)) * CAST(2.25 AS decimal(5,3)), 'Scale') AS int) AS mul_s;
