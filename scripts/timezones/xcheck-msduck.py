#!/usr/bin/env python3
"""Cross-checks the time zone model of scripts/gen-timezones.py against
msduck's independent captures (reference/at-time-zone-history-*.json: daily
offsets of every zone, years 0001-2500, SQL Server 17.0.4065.4).

Usage: python3 scripts/timezones/xcheck-msduck.py PATH/TO/msduck
(clone: git clone --depth 1 https://github.com/mirek/msduck.git)

Expected result (2026-10-03): all 345,109 daily changes agree except 47 at
0001-01-01 for zones west of UTC, where AT TIME ZONE clamps an underflowing
local time to +00:00 (an executor rule, not a zone rule).
"""
import collections
import glob
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('gen', os.path.join(HERE, '..', 'gen-timezones.py'))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

dump = json.load(open(g.DUMP))
models = {z: g.model_zone(z, dump) for z in dump['zones']}
TPD = g.TPD
total = 0
bad = collections.Counter()
examples = {}
for f in sorted(glob.glob(os.path.join(sys.argv[1], 'reference', 'at-time-zone-history-*.json'))):
    for chunk in json.load(open(f))['chunks']:
        q = chunk['daily']['query']
        start_s = q.split("CAST('")[1].split("'")[0]
        start = g.parse_ticks(start_s[:10] + ' 00:00:00.0000000')
        lo_k, hi_k = [int(x) for x in q.split('GENERATE_SERIES(')[1].split(')')[0].split(',')]
        want = collections.defaultdict(set)
        for z, k, p, o in chunk['daily']['reference']['sets'][0]['rows']:
            want[z].add((k, p, o))
        for z, segs in models.items():
            got = set()
            for t, _, _ in g.model_transitions(segs, start + lo_k * TPD, start + hi_k * TPD):
                k = -((start - t) // TPD)  # first sampled midnight at or after t
                if lo_k < k <= hi_k:
                    p = g.offset_at(segs, start + (k - 1) * TPD)
                    o = g.offset_at(segs, start + k * TPD)
                    if p != o:
                        got.add((k, p, o))
            w = want.get(z, set())
            total += len(w)
            if got != w:
                bad[z] += len(got ^ w)
                examples.setdefault(z, (start_s, sorted(got ^ w)[:4]))
    print(f'{os.path.basename(f)}: {total} daily changes so far, {sum(bad.values())} differences', flush=True)
for z, n in bad.most_common():
    print(z, n, examples[z])
