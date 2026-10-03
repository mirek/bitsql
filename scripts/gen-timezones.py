#!/usr/bin/env python3
"""Generates src/core/types/timezone_data.mbt (AT TIME ZONE rules).

Input: scripts/timezones/sqlserver-timezones.json, dumped from real SQL Server
by harness/src/dump-timezones.mjs (see its header). Every number in the output
is derived from SQL Server's own answers; nothing comes from IANA tzdata or
the Windows registry directly.

Model. For each sys.time_zone_info name the UTC timeline is cut into
segments. A segment starts at an observed transition instant (the first one
at -infinity) and holds either a fixed offset or an annual Windows-style rule
(standard/daylight offsets plus two "n-th weekday of month at local time"
transition specs, week 5 = last). SQL Server extrapolates the first yearly
rule backwards and the last one forwards; the sample windows of the dump
check that assumption at years 1..9999.

The script verifies, and fails loudly otherwise, that the model reproduces:
- every transition (exact 100 ns instant and offsets) of every scanned window,
  and no extra transitions, and the offset at every window start;
- sys.time_zone_info (current_utc_offset, is_currently_dst) at the dump time.
Local (wall-clock) input is fitted to the probes: changes whose repeated or
skipped wall times SQL Server reads in the offset after the change are listed
(tz_after_picks); wall-clock years whose probes the resolver still cannot
reproduce are listed as unsupported (an Emulator error at run time).

Outputs: src/core/types/timezone_data.mbt (the tables) and
src/core/types/timezone_data_test.mbt (a sample of SQL Server's answers that
the MoonBit port, src/core/types/timezone.mbt, must reproduce; it mirrors the
Python functions rule_offset, model_transitions and local_to_utc below).

Regenerate (see docs/reference/at-time-zone.md):
  cd harness && BITSQL_ORACLE_NAME=bitsql-oracle-tz BITSQL_ORACLE_PORT=47345 \\
    node src/dump-timezones.mjs ../scripts/timezones/sqlserver-timezones.json
  python3 scripts/gen-timezones.py && moon fmt && moon test -p mirek/bitsql/core/types
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUMP = os.path.join(ROOT, 'scripts/timezones/sqlserver-timezones.json')
OUT = os.path.join(ROOT, 'src/core/types/timezone_data.mbt')

TPS = 10_000_000
TPM = 60 * TPS
TPD = 86400 * TPS
NEG_INF = -(1 << 63)


def days_from_civil(y, m, d):
    y = y - 1 if m <= 2 else y
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    mp = (m + 9) % 12
    doy = (153 * mp + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468 + 719162


def civil_from_days(days):
    z = days - 719162 + 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    y = yoe + era * 400 + (1 if m <= 2 else 0)
    return y, m, d


def is_leap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


def dim(y, m):
    return [31, 29 if is_leap(y) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]


def dow(days):
    """0 = Sunday (Windows SYSTEMTIME.wDayOfWeek); 0001-01-01 is a Monday."""
    return (days + 1) % 7


def parse_ticks(s):
    date, time = s.split(' ')
    y, m, d = (int(x) for x in date.split('-'))
    hh, mm, rest = time.split(':')
    sec, frac = rest.split('.')
    frac = (frac + '0000000')[:7]
    return days_from_civil(y, m, d) * TPD + ((int(hh) * 60 + int(mm)) * 60 + int(sec)) * TPS + int(frac)


def fmt_ticks(t):
    if t == NEG_INF:
        return '-inf'
    days, rem = divmod(t, TPD)
    y, m, d = civil_from_days(days)
    s, f = divmod(rem, TPS)
    return f'{y:04d}-{m:02d}-{d:02d} {s // 3600:02d}:{s // 60 % 60:02d}:{s % 60:02d}.{f:07d}'


# ---------------------------------------------------------------- rules

def spec_day(year, spec):
    """Day number of (month, week 1..5 (5 = last), dow) in `year`."""
    month, week, wd = spec
    first = days_from_civil(year, month, 1)
    d = first + (wd - dow(first)) % 7 + (week - 1) * 7
    while d >= first + dim(year, month):
        d -= 7
    return d


def clamp_year(y):
    return 1 if y < 1 else 9999 if y > 9999 else y


def rule_bounds(rule, year):
    """(DST start, DST end) UTC instants of `rule` in rule year `year`."""
    std, dst, s_spec, s_tod, e_spec, e_tod = rule
    s = spec_day(year, s_spec) * TPD + s_tod - std * TPM
    e = spec_day(year, e_spec) * TPD + e_tod - dst * TPM
    return s, e


def rule_offset(rule, utc):
    """Offset of an annual rule at `utc`, the way SQL Server decides: the
    rule year Y is the year of the standard-time wall clock (utc + standard
    offset); the daylight-time wall clock (utc + daylight offset), moved into
    year Y (its own year is dropped), is compared with year Y's DST end (a
    daylight wall time) and DST start (a standard wall time, shifted into
    daylight time). In the hours where the two wall clocks are in different
    years this reproduces SQL Server's odd results (Central Brazilian
    Standard Time: DST end at 1903-01-01 04:00 UTC instead of 03:00, a
    one-hour standard-time blip at 1904-01-01 03:00 UTC)."""
    std, dst, s_spec, s_tod, e_spec, e_tod = rule
    y = clamp_year(civil_from_days((utc + std * TPM) // TPD)[0])
    days, tod = divmod(utc + dst * TPM, TPD)
    _, m, d = civil_from_days(days)
    wall = days_from_civil(y, m, d) * TPD + tod
    start = spec_day(y, s_spec) * TPD + s_tod + (dst - std) * TPM
    end = spec_day(y, e_spec) * TPD + e_tod
    if s_spec[0] < e_spec[0]:
        inside = start <= wall < end
    else:
        inside = wall < end or wall >= start
    return dst if inside else std


def rule_candidates(rule, lo, hi):
    """Instants in [lo, hi) where rule_offset may change."""
    std, dst = rule[0], rule[1]
    out = []
    y0 = civil_from_days(lo // TPD)[0] - 1
    y1 = civil_from_days((hi - 1) // TPD)[0] + 1
    for y in range(max(1, y0), min(9999, y1) + 1):
        s, e = rule_bounds(rule, y)
        jan1 = days_from_civil(y, 1, 1) * TPD
        for t in (s, e, jan1 - std * TPM, jan1 - dst * TPM):
            if lo <= t < hi:
                out.append(t)
    return out


def year_artifact(t, before, after):
    """A change exactly where the standard or daylight wall clock reaches
    00:00 Jan 1: an artifact of rule_offset's year handling, not a rule
    date (says nothing about the specs)."""
    for off in (before, after):
        days, tod = divmod(t + off * TPM, TPD)
        _, m, d = civil_from_days(days)
        if m == 1 and d == 1 and tod == 0:
            return True
    return False


def describe(t, before, after):
    """(year, candidate (month, week, dow, wall ticks) specs) of a transition,
    from the wall clock in the offset before it."""
    wall = t + before * TPM
    days, tod = divmod(wall, TPD)
    y, m, d = civil_from_days(days)
    weeks = {(d - 1) // 7 + 1}
    if d + 7 > dim(y, m):
        weeks.add(5)
    return y, {(m, w, dow(days), tod) for w in weeks}


class Group:
    """Consecutive transitions explained by one annual rule. Year artifacts
    are carried along without constraining the specs."""

    def __init__(self, t):
        self.items = [t]
        _, before, after = t
        self.std, self.dst = (before, after) if after > before else (after, before)
        self.cands = {}
        self.years = {}
        self.last_kind = None
        if not year_artifact(*t):
            self.take(t)

    @staticmethod
    def kind(t):
        return 'start' if t[2] > t[1] else 'end'

    def take(self, t):
        y, specs = describe(*t)
        k = self.kind(t)
        old = self.cands.get(k)
        self.cands[k] = set(specs) if old is None else old & specs
        self.years[k] = y
        self.last_kind = k

    def accepts(self, t):
        if t[1] == t[2]:
            return False
        if (min(t[1], t[2]), max(t[1], t[2])) != (self.std, self.dst):
            return False
        if year_artifact(*t):
            return True
        k = self.kind(t)
        if k == self.last_kind:
            return False
        y, specs = describe(*t)
        if k in self.years and y != self.years[k] + 1:
            return False
        return k not in self.cands or bool(self.cands[k] & specs)

    def add(self, t):
        self.items.append(t)
        if not year_artifact(*t):
            self.take(t)

    def rules(self):
        """Candidate rules, most likely first (week n before 'last')."""
        if 'start' not in self.cands or 'end' not in self.cands:
            return []
        def ranked(k):
            return sorted(self.cands[k], key=lambda s: (s[1] == 5, s))
        out = []
        for s in ranked('start'):
            for e in ranked('end'):
                out.append((self.std, self.dst, s[:3], s[3], e[:3], e[3]))
        return out


class Segment:
    def __init__(self, start, initial, rule):
        self.start = start      # first instant (inclusive); NEG_INF for the first
        self.initial = initial  # fixed offset (rule is None)
        self.rule = rule
        self.daylight = False   # fixed offset that is daylight saving time


def mark_daylight(segs):
    """A fixed segment is daylight saving time when it starts with an
    increase that the next change, within a year, reverses (DST periods that
    SQL Server's yearly rules hold but this model keeps as fixed offsets;
    checked against sys.time_zone_info.is_currently_dst)."""
    for i, s in enumerate(segs):
        if s.rule is not None or s.start == NEG_INF:
            continue
        b = offset_at(segs, s.start - 1)
        if s.initial <= b:
            continue
        nxt = model_transitions(segs, s.start, s.start + 366 * TPD)
        s.daylight = bool(nxt) and nxt[0][2] == b
    return segs


def find_segment(segs, t):
    lo, hi = 0, len(segs) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if segs[mid].start <= t:
            lo = mid
        else:
            hi = mid - 1
    return lo


def offset_at(segs, t):
    s = segs[find_segment(segs, t)]
    return s.initial if s.rule is None else rule_offset(s.rule, t)


def model_transitions(segs, lo, hi):
    """Offset changes of the model with instant in (lo, hi]."""
    cands = set()
    for i, s in enumerate(segs):
        end = segs[i + 1].start if i + 1 < len(segs) else hi + 1
        a = max(lo + 1, s.start)
        b = min(hi + 1, end)
        if a >= b:
            continue
        if s.start == a:
            cands.add(a)
        if s.rule is not None:
            cands.update(rule_candidates(s.rule, a, b))
    out = []
    for t in sorted(cands):
        b, a = offset_at(segs, t - 1), offset_at(segs, t)
        if b != a:
            out.append((t, b, a))
    return out


def make_groups(transitions):
    """Greedy rule groups of consecutive transitions."""
    groups = []
    for t in transitions:
        if groups and groups[-1].accepts(t):
            groups[-1].add(t)
        else:
            groups.append(Group(t))
    # a year artifact can split a run of one rule: merge such neighbours
    merged = []
    for g in groups:
        if merged and len(g.items) >= 3 and len(merged[-1].items) >= 3 and g.rules() and \
                g.rules()[0] == merged[-1].rules()[0] and g.items[0][0] - merged[-1].items[-1][0] < 400 * TPD:
            for t in g.items:
                merged[-1].items.append(t)
                if not year_artifact(*t):
                    merged[-1].take(t)
        else:
            merged.append(g)
    return merged


def group_segments(groups, choice):
    """Segments starting at each group's first transition: a rule segment
    for a group of 3+ transitions with a rule, else one fixed segment per
    transition."""
    segs = []
    for gi, g in enumerate(groups):
        rules = g.rules() if len(g.items) >= 3 else []
        if rules:
            segs.append(Segment(g.items[0][0], None, rules[min(choice.get(gi, 0), len(rules) - 1)]))
        else:
            for t in g.items:
                segs.append(Segment(t[0], t[2], None))
    return segs


def build(initial, transitions, choice, transitions_lo):
    """Segments from greedy rule groups; choice[i] picks group i's rule
    among its candidates (for groups that extrapolate). A first rule group
    starting in the first scanned year extends to -infinity."""
    groups = make_groups(transitions)
    segs = group_segments(groups, choice)
    if segs and segs[0].rule is not None and groups[0].items[0][0] - transitions_lo < 400 * TPD:
        segs[0].start = NEG_INF
    else:
        segs.insert(0, Segment(NEG_INF, initial, None))
    return segs, groups


def fix(zone, segs, transitions, lo, hi):
    """Where the model and SQL Server disagree inside the main window, ends
    the rule segment at the first divergence and models the observed
    transitions up to the next segment afresh (a rule segment wrong at its
    own start becomes fixed offsets)."""
    want = [t for t in transitions if lo < t[0] <= hi]
    for _ in range(100000):
        got = model_transitions(segs, lo, hi)
        if got == want:
            return segs
        k = 0
        while k < min(len(got), len(want)) and got[k] == want[k]:
            k += 1
        at = min(x[0] for x in (got[k] if k < len(got) else None, want[k] if k < len(want) else None) if x is not None)
        i = find_segment(segs, at)
        s = segs[i]
        if s.rule is None:
            raise SystemExit(f'{zone}: cannot model {fmt_ticks(at)}')
        nxt = segs[i + 1].start if i + 1 < len(segs) else None
        rest = [t for t in want if t[0] >= at and (nxt is None or t[0] < nxt)]
        if s.start == at:
            new = [Segment(t[0], t[2], None) for t in rest]
            segs = segs[:i] + new + segs[i + 1:]
            continue
        new = group_segments(make_groups(rest), {})
        if not new or new[0].start != at:
            new.insert(0, Segment(at, offset_at(segs, at - 1), None))
        segs = segs[:i + 1] + new + segs[i + 1:]
    raise SystemExit(f'{zone}: no convergence')


def wall_range(t, b, a):
    """Wall-clock times a change at `t` (offset b → a) repeats or skips."""
    return min(t + b * TPM, t + a * TPM), max(t + b * TPM, t + a * TPM)


def local_to_utc(segs, local, after_picks):
    """SQL Server's resolution of a wall-clock time: (utc, shown offset).
    A wall time a change repeats or skips is read in the offset before the
    change (daylight saving: repeated times are daylight time, skipped ones
    are read in standard time and land after the change), except for the
    changes in `after_picks` ((UTC instant, wall-clock year) pairs: a range
    spanning a new year can resolve differently on each side), which SQL
    Server reads in the offset after the change. Mirrors tz_local_to_utc in
    src/core/types/timezone.mbt."""
    span = 1000 * TPM
    for t, b, a in model_transitions(segs, local - span, local + span):
        lo, hi = wall_range(t, b, a)
        if lo <= local < hi:
            o = a if (t, civil_from_days(local // TPD)[0]) in after_picks else b
            utc = local - o * TPM
            return utc, offset_at(segs, utc)
    o = offset_at(segs, local - offset_at(segs, local - span) * TPM)
    if offset_at(segs, local - o * TPM) != o:
        o = offset_at(segs, local - offset_at(segs, local + span) * TPM)
    return local - o * TPM, o


def probe_locals(segs, t):
    before = offset_at(segs, t - 1)
    after = offset_at(segs, t)
    L = t + before * TPM
    d = abs(after - before)
    return before, after, [L - 1, L, L + d * 30 * TPS, L + d * TPM - 1, L + d * TPM]


def fit_local(zone, segs, probes):
    """From SQL Server's answers to the probes: the changes whose repeated or
    skipped wall times are read in the offset after the change, and the
    wall-clock years where SQL Server resolves local times in ways this
    model does not reproduce (rejected with an emulator error)."""
    after_picks = set()
    bad_years = set()
    observed = {}
    for at, results in probes.items():
        t = parse_ticks(at)
        _, _, locs = probe_locals(segs, t)
        for local, (shown, used) in zip(locs, results):
            used = float(used)
            for t2, b2, a2 in model_transitions(segs, local - 1000 * TPM, local + 1000 * TPM):
                lo, hi = wall_range(t2, b2, a2)
                if lo <= local < hi:
                    pick = 'before' if used == b2 else 'after' if used == a2 else 'bad'
                    observed.setdefault((t2, civil_from_days(local // TPD)[0]), set()).add(pick)
    for key, picks in observed.items():
        if picks == {'after'}:
            after_picks.add(key)
        elif picks != {'before'}:
            bad_years.add(key[1])
    for at, results in probes.items():
        t = parse_ticks(at)
        _, _, locs = probe_locals(segs, t)
        for local, (shown, used) in zip(locs, results):
            utc, sh = local_to_utc(segs, local, after_picks)
            if sh != shown or abs((local - utc) / TPM - float(used)) > 1e-9:
                bad_years.add(civil_from_days(local // TPD)[0])
    return after_picks, bad_years


def window_bounds(w):
    lo = parse_ticks(w['start'] + ' 00:00:00.0000000')
    return lo, lo + w['steps'] * w['stepMinutes'] * TPM


def check_windows(segs, windows, scans):
    """First disagreement with SQL Server over all scanned windows, or None."""
    for w, sc in zip(windows, scans):
        lo, hi = window_bounds(w)
        if offset_at(segs, lo) != sc['initial']:
            return f'offset at {w["start"]} is {offset_at(segs, lo)}, SQL Server {sc["initial"]}'
        want = [(parse_ticks(a), b, c) for a, b, c in sc['transitions']]
        got = model_transitions(segs, lo, hi)
        if got != want:
            diff = sorted((fmt_ticks(x[0]), x[1], x[2], 'model' if x in got else 'sql') for x in set(got) ^ set(want))
            return f'window {w["start"]} differs: {diff[:6]}'
    return None


def model_zone(zone, dump):
    windows = dump['windows']
    scans = dump['scans'][zone]
    trans = [(parse_ticks(a), b, c) for a, b, c in scans[0]['transitions']]
    lo, hi = window_bounds(windows[0])
    _, groups = build(scans[0]['initial'], trans, {}, lo)
    last = len(groups) - 1
    nfirst = max(1, len(groups[0].rules())) if groups else 1
    nlast = max(1, len(groups[-1].rules())) if groups else 1
    error = None
    for cf in range(min(nfirst, 16)):
        for cl in range(min(nlast, 16)):
            segs, _ = build(scans[0]['initial'], trans, {0: cf, last: cl} if last > 0 else {0: cf}, lo)
            segs = fix(zone, segs, trans, lo, hi)
            error = check_windows(segs, windows, scans)
            if error is None:
                return mark_daylight(segs)
    raise SystemExit(f'{zone}: {error}')


def main():
    dump = json.load(open(DUMP))
    out_zones = []
    total_probes = 0
    failures = []
    plo = parse_ticks(dump['probeFrom'] + ' 00:00:00.0000000')
    phi = parse_ticks(dump['probeTo'] + ' 00:00:00.0000000')
    wlo, whi = window_bounds(dump['windows'][0])
    for zone in dump['zones']:
        segs = model_zone(zone, dump)
        probes = dump['probes'][zone]
        total_probes += sum(len(p) for p in probes.values())
        after_picks, bad_years = fit_local(zone, segs, probes)
        # outside the probed years only plain daylight-saving rules may change
        # the offset; anything else stays unsupported for local input
        for t, b, a in model_transitions(segs, wlo, whi):
            if plo <= t < phi:
                continue
            s = segs[find_segment(segs, t)]
            if s.rule is None or s.start == t:
                bad_years.add(civil_from_days(t // TPD)[0])
        out_zones.append((zone, segs, sorted(after_picks), sorted(bad_years)))
    cat = dump.get('catalog')
    if cat:
        now = parse_ticks(cat['at'])
        # SQL Server reads its local clock (UTC in the dump container) as a
        # wall-clock time in each zone
        for (zone, segs, picks, _), (name, cur, isdst) in zip(out_zones, cat['rows']):
            utc, off = local_to_utc(segs, now, set(picks))
            s = segs[find_segment(segs, utc)]
            dst = s.daylight if s.rule is None else s.rule[0] != s.rule[1] and rule_offset(s.rule, utc) == s.rule[1]
            text = ('-' if off < 0 else '+') + f'{abs(off) // 60:02d}:{abs(off) % 60:02d}'
            if name != zone or text != cur or dst != isdst:
                failures.append(f'catalog {name}: model ({zone}, {text}, {dst}) SQL Server ({cur}, {isdst})')
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        raise SystemExit(f'{len(failures)} failures')
    emit(dump, out_zones)
    emit_test(dump, out_zones)
    nseg = sum(len(z[1]) for z in out_zones)
    npick = sum(len(z[2]) for z in out_zones)
    bad = [(z[0], y) for z in out_zones for y in z[3]]
    print(f'{len(out_zones)} zones, {nseg} segments, {npick} after-picks, {total_probes} probes', file=sys.stderr)
    print(f'unsupported local years: {bad}', file=sys.stderr)


def emit(dump, zones):
    rules = []
    rule_ix = {}
    seg_rows = []
    first = []
    picks = []
    bad = []
    for zi, (_, segs, after_picks, bad_years) in enumerate(zones):
        first.append(len(seg_rows))
        for s in segs:
            r = -1
            if s.rule is not None:
                if s.rule not in rule_ix:
                    rule_ix[s.rule] = len(rules)
                    rules.append(s.rule)
                r = rule_ix[s.rule]
            seg_rows.append((s.start, 0 if s.initial is None else s.initial, r, s.daylight))
        picks += [(zi, t, y) for t, y in after_picks]
        bad += [(zi, y) for y in bad_years]
    first.append(len(seg_rows))
    L = []
    L.append('// Generated by scripts/gen-timezones.py from scripts/timezones/sqlserver-timezones.json')
    L.append(f'// (SQL Server {dump["server"]}, dumped by harness/src/dump-timezones.mjs). Do not edit.')
    L.append('')
    L.append('///|')
    L.append('/// sys.time_zone_info names in catalog order.')
    L.append('let tz_names : Array[String] = [')
    for z in zones:
        L.append(f'  "{z[0]}",')
    L.append(']')
    L.append('')
    L.append('///|')
    L.append('/// Segments of zone i are tz_segments[tz_first[i]..tz_first[i + 1]].')
    L.append('let tz_first : Array[Int] = [' + ', '.join(str(x) for x in first) + ']')
    L.append('')
    L.append('///|')
    L.append('/// (start UTC ticks or tz_neg_inf, fixed offset in minutes, annual rule')
    L.append('/// index or -1 for a fixed offset, fixed offset is daylight time).')
    L.append('let tz_segments : Array[(Int64, Int, Int, Bool)] = [')
    for st, ini, r, dl in seg_rows:
        stv = 'tz_neg_inf' if st == NEG_INF else f'{st}L'
        L.append(f'  ({stv}, {ini}, {r}, {str(dl).lower()}),')
    L.append(']')
    L.append('')
    L.append('///|')
    L.append('/// Annual rules: (standard offset, daylight offset, start month, week')
    L.append('/// (5 = last), weekday (0 = Sunday), start wall ticks in standard time,')
    L.append('/// end month, week, weekday, end wall ticks in daylight time).')
    L.append('let tz_rules : Array[(Int, Int, Int, Int, Int, Int64, Int, Int, Int, Int64)] = [')
    for std, dst, (sm, sw, sd), stod, (em, ew, ed), etod in rules:
        L.append(f'  ({std}, {dst}, {sm}, {sw}, {sd}, {stod}L, {em}, {ew}, {ed}, {etod}L),')
    L.append(']')
    L.append('')
    L.append('///|')
    L.append('/// (zone, UTC instant, wall-clock year) of offset changes whose repeated')
    L.append('/// or skipped wall times of that year SQL Server reads in the offset after')
    L.append('/// the change.')
    L.append('let tz_after_picks : Array[(Int, Int64, Int)] = [')
    for zi, t, y in picks:
        L.append(f'  ({zi}, {t}L, {y}),')
    L.append(']')
    L.append('')
    L.append('///|')
    L.append('/// (zone, wall-clock year) where local (datetime/datetime2) input is not')
    L.append('/// resolved like SQL Server by this model: rejected with an emulator error.')
    L.append('let tz_unsupported_local_years : Array[(Int, Int)] = [')
    for zi, y in bad:
        L.append(f'  ({zi}, {y}),')
    L.append(']')
    open(OUT, 'w').write('\n'.join(L) + '\n')


def emit_test(dump, zones):
    """src/core/types/timezone_data_test.mbt: a sample of SQL Server's own
    answers from the dump (not the model's), so the MoonBit port is checked
    against the same evidence as the Python model."""
    trans = []
    probes = []
    for zone, segs, picks, bad in zones:
        scans = dump['scans'][zone]
        main_t = scans[0]['transitions']
        keep = [t for t in main_t if t[0][:4] in ('1900', '1903', '1904', '1970', '2000', '2010', '2011',
                                                   '2014', '2016', '2018', '2022', '2024', '2026', '2030', '2101')]
        for sc in scans[1:]:
            keep += sc['transitions']
        trans += [(zone, parse_ticks(a), b, c) for a, b, c in keep]
        pick_ts = {t for t, _ in picks}
        for i, (at, results) in enumerate(sorted(dump['probes'][zone].items())):
            t = parse_ticks(at)
            if t not in pick_ts and i % 12 != 0:
                continue
            _, _, locs = probe_locals(segs, t)
            for local, (shown, used) in zip(locs, results):
                if civil_from_days(local // TPD)[0] in bad:
                    continue
                utc = local - round(float(used) * TPM)
                probes.append((zone, local, utc, shown))
    L = ['// Generated by scripts/gen-timezones.py: a sample of SQL Server\'s answers in',
         '// scripts/timezones/sqlserver-timezones.json. Do not edit.', '',
         '///|', '/// (zone, UTC ticks of an offset change, offset before, offset after)',
         'let tz_sql_transitions : Array[(String, Int64, Int, Int)] = [']
    L += [f'  ("{z}", {t}L, {b}, {a}),' for z, t, b, a in trans]
    L += [']', '', '///|', '/// (zone, local datetime2 ticks, UTC ticks of the result, offset shown)',
          'let tz_sql_local : Array[(String, Int64, Int64, Int)] = [']
    L += [f'  ("{z}", {l}L, {u}L, {o}),' for z, l, u, o in probes]
    L += [']', '', '///|', 'test "timezone: offset changes match SQL Server" {',
          '  for c in tz_sql_transitions {',
          '    let (name, t, before, after) = c',
          '    let z = @types.tz_lookup(name).unwrap()',
          '    assert_eq(@types.tz_offset_at(z, t - 1L), before, msg="\\{name} before \\{t}")',
          '    assert_eq(@types.tz_offset_at(z, t), after, msg="\\{name} at \\{t}")',
          '  }', '}', '', '///|', 'test "timezone: local times resolve like SQL Server" {',
          '  for c in tz_sql_local {',
          '    let (name, wall, utc, shown) = c',
          '    let z = @types.tz_lookup(name).unwrap()',
          '    assert_eq(@types.tz_local_to_utc(z, wall), (utc, shown), msg="\\{name} \\{wall}")',
          '  }', '}']
    open(os.path.join(ROOT, 'src/core/types/timezone_data_test.mbt'), 'w').write('\n'.join(L) + '\n')
    print(f'test: {len(trans)} transitions, {len(probes)} local probes', file=sys.stderr)


if __name__ == '__main__':
    main()
