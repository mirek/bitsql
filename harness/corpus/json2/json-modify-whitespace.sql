-- JSON_MODIFY edits text in place: an inserted member goes right before the
-- closing brace/bracket (",\"k\":v", no comma into an empty container); a
-- deleted member takes the following comma (first member) or the preceding
-- comma (later members) with it, other whitespace stays.
SELECT JSON_MODIFY(N'{"a":1 }', '$.b', 2) a, JSON_MODIFY(N'{ }', '$.b', 2) b, JSON_MODIFY(N'{}', '$.b', 2) c, JSON_MODIFY(N'{ "a" : 1 }', '$.b', 2) d, JSON_MODIFY(N'{"a":1,
"c":2
}', '$.b', 2) e;
SELECT JSON_MODIFY(N'[1, 2 ]', 'append $', 3) a, JSON_MODIFY(N'[ ]', 'append $', 3) b, JSON_MODIFY(N'[]', 'append $', 3) c, JSON_MODIFY(N'{"a":[ 1 ] }', 'append $.a', 3) d;
SELECT JSON_MODIFY(N'{ "a":1 , "b":2}', '$.a', NULL) a, JSON_MODIFY(N'{"a":1}', '$.a', NULL) b, JSON_MODIFY(N'{ "a" : 1 }', '$.a', NULL) c, JSON_MODIFY(N'{"b":2,"a":1 }', '$.a', NULL) d, JSON_MODIFY(N'{"b":2 , "a":1, "c":3}', '$.a', NULL) e;
SELECT JSON_MODIFY(N'  {"a":1}  ', '$.a', 7) a, JSON_MODIFY(N'{"a":1,"b":2}', '$.a', NULL) b, JSON_MODIFY(N'{"b":2,"a":1}', '$.a', NULL) c, JSON_MODIFY(N'{"b":2, "a":1 , "c":3}', '$.a', NULL) d;
SELECT JSON_MODIFY(N'{"ab":1}', '$.ab', 2) a, JSON_MODIFY(N'{"a":"x\ny"}', '$.b', 2) b, JSON_MODIFY(N'{"a":{"b":1}, "c":[1, {"d":2}]}', '$.c[1].d', NULL) c;
