#!/usr/bin/env python3
"""Flat profile from scripts/profile/sampler.c output (see scripts/profile.sh).

  report.py DATA EXE [--top N]            self and inclusive time per function
  report.py DATA EXE --callers FUNC       first bitsql caller of FUNC's samples
                                          (FUNC: substring, e.g. drop_object)
  report.py DATA EXE --focus FUNC         only samples with FUNC on the stack
                                          (e.g. rpc__executesql)
"""
import argparse, collections, re, struct, subprocess

DEPTH = 64  # must match sampler.c
RUNTIME = re.compile(r'^(moonbit_|_mi_|mi_|\?|scan_|_M0[A-Z]+PC|_M0[A-Z]+PB)')

def short(f):
    # _M0FP45mirek6bitsql4core4exec4eval -> exec.eval (length-prefixed path)
    m = re.match(r'^_M0([A-Z]+)P(\d)(.*)$', f)
    if not m: return f
    rest, parts = m.group(3), []
    while True:
        n = re.match(r'(\d+)', rest)
        if not n: break
        k = int(n.group(1)); s = rest[len(n.group(1)):]
        parts.append(s[:k]); rest = s[k:]
    parts = [p for p in parts if p not in ('mirek', 'bitsql', 'core', 'moonbitlang')]
    return '.'.join(parts) + ('' if not rest else ' ' + rest[:40])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('data'); ap.add_argument('exe')
    ap.add_argument('--top', type=int, default=30)
    ap.add_argument('--callers')
    ap.add_argument('--focus')
    a = ap.parse_args()
    base = next(int(l.split('-')[0], 16) for l in open(a.data + '.maps') if l.rstrip().endswith(a.exe.split('/')[-1]))
    raw = open(a.data, 'rb').read(); rec = 8 * (DEPTH + 1)
    samples = []
    for off in range(0, len(raw) - rec + 1, rec):
        w = struct.unpack_from('<%dQ' % (DEPTH + 1), raw, off)
        samples.append(w[2:1 + w[0]])  # drop the signal handler frame
    addrs = sorted({x for s in samples for x in s if 0 <= x - base < 1 << 28})
    out = subprocess.run(['addr2line', '-f', '-e', a.exe] + ['%x' % (x - base - 1) for x in addrs],
                         capture_output=True, text=True).stdout.split('\n')
    name = {x: out[2 * i] for i, x in enumerate(addrs)}
    stacks = []
    for s in samples:
        fs = [name.get(x, '?') for x in s]
        if fs and fs[0] == '?' and len(fs) > 1: fs = fs[1:]  # libc trampoline
        if fs: stacks.append(fs)
    if a.focus:
        total = len(stacks)
        stacks = [fs for fs in stacks if any(a.focus in f for f in fs)]
        print(f'focus {a.focus}: {len(stacks)} of {total} samples')
    n = len(stacks)
    print(f'{n} samples (proportions only: SIGPROF samples undercount CPU ~2x; bench/profile.mjs prints exact server CPU)')
    if a.callers:
        c = collections.Counter(); hits = 0
        for fs in stacks:
            if a.callers not in fs[0]: continue
            hits += 1
            c[short(next((f for f in fs if not RUNTIME.match(f)), '?'))] += 1
        print(f'--- callers of {a.callers}: {hits} samples ({100 * hits / max(n, 1):.1f}%)')
        for f, k in c.most_common(a.top): print(f'{100 * k / hits:5.1f}% {f}')
        return
    selfc = collections.Counter(fs[0] for fs in stacks)
    incl = collections.Counter(f for fs in stacks for f in set(fs))
    print('--- self')
    for f, k in selfc.most_common(a.top): print(f'{100 * k / n:5.1f}% {short(f)}')
    print('--- inclusive')
    for f, k in incl.most_common(a.top + 15):
        if RUNTIME.match(f) and not f.startswith(('moonbit_', '_mi_', 'mi_')): continue
        print(f'{100 * k / n:5.1f}% {short(f)}')

main()
