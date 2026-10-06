#!/usr/bin/env python3
"""Generate SQL inputs at every pinned RE2 property boundary and fold pair.

Expected output must be captured by the harness from SQL Server, never from
these reference tables. Boundary probes identify version differences too.
"""
import json
import re
from pathlib import Path
root=Path(__file__).resolve().parents[1]
vendor=root/'docs/reference/vendor/re2/probes-15.1'
data=(vendor/'unicode_groups.cc').read_text()
ranges={name:[(int(a),int(b)) for a,b in re.findall(r'\{ (\d+), (\d+) \}',body)] for name,body in re.findall(r'static const URange(?:16|32) (\w+)\[\] = \{(.*?)\};',data,re.S)}
def sqltext(cp):
    return "CONVERT(nvarchar(2),0x"+chr(cp).encode('utf-16-le').hex()+")"
cases=[]
for name,r16,r32 in re.findall(r'\{ "([^"]+)", \+1, (\w+), \d+, (\w+), \d+ \}',data):
    points=sorted({v for a,b in ranges.get(r16,[])+ranges.get(r32,[]) for v in [a-1,a,b,b+1] if 0<=v<=0x10ffff and not 0xd800<=v<=0xdfff})
    for start in range(0,len(points),256):
        rows=','.join(f'({cp},{sqltext(cp)})' for cp in points[start:start+256])
        sql=f"SELECT cp, CASE WHEN REGEXP_LIKE(ch, N'\\p{{{name}}}') THEN 1 ELSE 0 END AS matches FROM (VALUES {rows}) v(cp,ch) ORDER BY cp;"
        cases.append({'name':name+'-'+str(start//256),'steps':[{'kind':'batch','sql':sql}]})
body=(vendor/'unicode_casefold.cc').read_text().split('const CaseFold unicode_casefold[] = {')[1].split('};')[0]
pairs=[]
for a,b,d in re.findall(r'\{ (\d+), (\d+), ([\w-]+) \}',body):
    for cp in range(int(a),int(b)+1):
        other=cp^1 if d=='EvenOdd' else ((cp-1)^1)+1 if d=='OddEven' else cp+int(d)
        pairs.append((cp,other))
for start in range(0,len(pairs),128):
    rows=','.join(f'({cp},{other},{sqltext(cp)},{sqltext(other)})' for cp,other in pairs[start:start+128])
    sql=f"SELECT cp, other_cp, REGEXP_COUNT(ch, other_ch, 1, 'i') AS matches FROM (VALUES {rows}) v(cp,other_cp,ch,other_ch) ORDER BY cp;"
    cases.append({'name':'fold-'+str(start//128),'steps':[{'kind':'batch','sql':sql}]})
p=root/'harness/corpus/sql2025/regex-unicode-boundaries.cases.json'
p.write_text(json.dumps({'source':'RE2 2025-11-05 Unicode 15.1 boundaries and simple-fold pairs; expected results captured from SQL Server','cases':cases},indent=2)+'\n')
print(len(cases),'cases')
