-- Unicode → varchar (code page 1252) converts each UTF-16 code unit on its
-- own: exact mapping, else Windows "best fit" (Ā → A, ł → l, ∞ → 8,
-- U+0301 → ´ 0xB4), else '?'. Surrogate halves become '?' each, so a
-- supplementary character is "??". Non-N literals convert the same way.
-- Varchar data compares as bytes under binary collations.
SELECT CAST(CAST(N'e' + NCHAR(769) AS varchar(10)) AS varbinary(10)) AS combining,
       CAST(CAST(N'🦆' AS varchar(10)) AS varbinary(10)) AS pair,
       CAST('Āłx🦆' AS varbinary(10)) AS literal,
       CAST(CAST(NCHAR(256) + NCHAR(8734) + NCHAR(19968) AS varchar(10)) AS varbinary(10)) AS mixed,
       CAST(N'Ā' AS varchar(1)) AS one,
       DATALENGTH(CAST(N'🦆' AS varchar(10))) AS pair_len,
       CAST(N'ĐđŁłŒœŠšŽžŸƒ' AS varchar(20)) AS latin_ext,
       CAST(N'‘’“”•–—€™' AS varchar(20)) AS punctuation,
       CAST(N'ΑΒΓ ДЖ 日本' AS varchar(20)) AS other_scripts,
       ASCII(N'Ā') AS ascii_best_fit;
SELECT CASE WHEN CAST(N'€' AS varchar(5)) COLLATE Latin1_General_100_BIN2 < CAST(NCHAR(160) AS varchar(5)) THEN 1 ELSE 0 END AS bin2_bytes,
       CASE WHEN N'€' COLLATE Latin1_General_100_BIN2 < NCHAR(160) THEN 1 ELSE 0 END AS bin2_units,
       CASE WHEN CAST(N'Ÿ' AS varchar(5)) COLLATE Latin1_General_BIN < CAST(N'ÿ' AS varchar(5)) THEN 1 ELSE 0 END AS bin_bytes;
SELECT CASE WHEN 'ß' = 'ss' THEN 1 ELSE 0 END AS varchar_eq,
       CASE WHEN N'ß' = N'ss' THEN 1 ELSE 0 END AS nvarchar_eq,
       CASE WHEN 'ß' > 'ss' THEN 1 ELSE 0 END AS after_ss,
       CASE WHEN 'ß' < 'st' THEN 1 ELSE 0 END AS before_st,
       CHARINDEX('ss', 'straße') AS varchar_find,
       CHARINDEX(N'ss', N'straße') AS nvarchar_find;
