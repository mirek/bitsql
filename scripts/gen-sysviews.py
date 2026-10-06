#!/usr/bin/env python3
"""Generates src/core/session/sysviews_data.mbt.

Inputs (both captured from real SQL Server, never hand-written):
- harness/corpus/catalog/view-descriptors.expected.json: result descriptors of
  `SELECT * FROM <view> WHERE 1 = 0` for every emulated catalog view (column
  order, wire type, nullability, computed flag, collation).
- scripts/sysviews-seed.json: seed rows of a fresh database (system objects
  in sys.objects, sys.schemas, sys.types, sys.databases), dumped from the
  oracle by harness/src/dump-sysviews-seed.mjs (node src/dump-sysviews-seed.mjs ../scripts/sysviews-seed.json) (see the sys skill findings).

Run: python3 scripts/gen-sysviews.py && moon fmt
"""
import json
import os
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Descriptor captures, in view_defs order (view ids are indexes: append new
# files at the end).
DESCRIPTORS = ['catalog/view-descriptors', 'catalog/view-descriptors-variant', 'catalog/view-descriptors-types', 'catalog/view-descriptors-schema', 'catalog/view-descriptors-settings', 'tail/catalog-view-descriptors-system', 'catalog/view-descriptors-storage', 'catalog/view-descriptors-scoped', 'catalog/view-descriptors-json-indexes', 'catalog/view-descriptors-json-internal']
CORPUS = os.path.join(ROOT, 'harness/corpus')
SYSTEM = os.path.join(ROOT, 'scripts/system-catalog')
OUT_SYSTEM = os.path.join(ROOT, 'src/core/session/sysviews_system_data.mbt')
SEED = os.path.join(ROOT, 'scripts/sysviews-seed.json')
OUT = os.path.join(ROOT, 'src/core/session/sysviews_data.mbt')

SKIP = set()

EXTRA_VIEWS = '''  {
    // read as sys.dm_exec_cursors(session_id) (bind_table_function)
    schema: "sys",
    name: "dm_exec_cursors",
    columns: [
      vc("session_id", Int, false, false),
      vc("cursor_id", Int, false, false),
      vc("name", NVarChar(Some(128), coll_default), true, false),
      vc("properties", NVarChar(Some(128), coll_default), false, false),
      vc("sql_handle", VarBinary(Some(64)), true, false),
      vc("statement_start_offset", Int, true, false),
      vc("statement_end_offset", Int, true, false),
      vc("plan_generation_num", BigInt, true, false),
      vc("creation_time", DateTime, true, false),
      vc("is_open", Bit, false, false),
      vc("is_async_population", Bit, false, false),
      vc("is_close_on_commit", Bit, false, false),
      vc("fetch_status", Int, false, false),
      vc("fetch_buffer_size", Int, false, false),
      vc("fetch_buffer_start", Int, false, false),
      vc("ansi_position", Int, false, false),
      vc("worker_time", BigInt, false, false),
      vc("reads", BigInt, false, false),
      vc("writes", BigInt, false, false),
      vc("dormant_duration", BigInt, false, false),
    ],
  },
'''


def collation(c):
    if c is None:
        return None
    key = (c['lcid'], c['flags'], c['sortId'], c['version'])
    if key == (1033, 13, 52, 0):
        return 'coll_default'
    if key == (1033, 1, 0, 0):
        return 'coll_ks_ws'
    if key == (1033, 96, 0, 2):
        return '@types.json_collation'
    raise SystemExit(f'unknown collation {c}')


def sql_type(c):
    t, n = c['type'], c['length']
    co = collation(c['collation'])
    if t in ('Bit', 'BitN'):
        return 'Bit'
    if t == 'TinyInt' or (t == 'IntN' and n == 1):
        return 'TinyInt'
    if t == 'SmallInt' or (t == 'IntN' and n == 2):
        return 'SmallInt'
    if t == 'Int' or (t == 'IntN' and n == 4):
        return 'Int'
    if t == 'BigInt' or (t == 'IntN' and n == 8):
        return 'BigInt'
    if t == 'DateTime' or (t == 'DateTimeN' and n == 8):
        return 'DateTime'
    if t == 'SmallDateTime' or (t == 'DateTimeN' and n == 4):
        return 'SmallDateTime'
    if t == 'Float' or (t == 'FloatN' and n == 8):
        return 'Float'
    if t == 'Real' or (t == 'FloatN' and n == 4):
        return 'Real'
    if t == 'Binary':
        return f'Binary({n})'
    if t == 'NChar':
        return f'NChar({n // 2}, {co})'
    if t == 'UniqueIdentifier':
        return 'UniqueIdentifier'
    if t == 'NVarChar':
        return f'NVarChar({"None" if n == 65535 else f"Some({n // 2})"}, {co})'
    if t == 'VarChar':
        return f'VarChar({"None" if n == 65535 else f"Some({n})"}, {co})'
    if t == 'Char':
        return f'Char({n}, {co})'
    if t == 'VarBinary':
        return f'VarBinary(Some({n}))'
    if t == 'Variant':
        return 'Variant'
    if t in ('Numeric', 'NumericN'):
        return f'Numeric({c["precision"]}, {c["scale"]})'
    raise SystemExit(f'unknown type {c}')


def mbt_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def datetime_value(text):
    text = text.rstrip('Z')
    d = datetime.fromisoformat(text)
    days = (d.date() - datetime(1900, 1, 1).date()).days
    secs = d.hour * 3600 + d.minute * 60 + d.second + d.microsecond / 1e6
    return f'DateTime({days}, {round(secs * 300)})'


def value(v, ty):
    if v is None:
        return 'Null'
    if ty == 'Bit':
        return f'Bit({"true" if v else "false"})'
    if ty in ('TinyInt', 'SmallInt', 'Int'):
        return f'{ty}({v})'
    if ty == 'BigInt':
        return f'BigInt({v}L)'
    if ty == 'DateTime':
        return datetime_value(v)
    if ty == 'UniqueIdentifier':
        return f'Guid(@types.parse_guid({mbt_str(v)}).unwrap())'
    if ty.startswith('VarBinary'):
        data = ''.join(f'\\x{b:02x}' for b in v['data'])
        return f'Binary(b"{data}")'
    return f'String({mbt_str(v)})'


def main():
    views = []
    desc = []
    for name in DESCRIPTORS:
        views += [l.split()[3] for l in open(os.path.join(CORPUS, name + '.sql')) if l.startswith('SELECT')]
        desc += json.load(open(os.path.join(CORPUS, name + '.expected.json')))['steps'][0]['sets']
    seed = json.load(open(SEED))
    out = []
    w = out.append
    w('// Generated by scripts/gen-sysviews.py from oracle captures')
    w('// (harness/corpus/catalog/view-descriptors.expected.json,')
    w('// scripts/sysviews-seed.json). Do not edit by hand.')
    w('')
    w('///|')
    w('/// Catalog view result descriptors, in SQL Server column order.')
    w('let view_defs : Array[ViewDef] = [')
    types_by_view = {}
    for v, s in zip(views, desc):
        if v in SKIP:
            continue
        schema, name = v.split('.')
        cols = []
        tys = {}
        for c in s['columns']:
            ty = sql_type(c)
            nullable = 'true' if c['flags'] & 1 else 'false'
            computed = 'true' if c['flags'] & 0x20 else 'false'
            cols.append(f'vc({mbt_str(c["name"])}, {ty}, {nullable}, {computed})')
            tys[c['name']] = ty
        types_by_view[v] = tys
        w(f'  {{ schema: {mbt_str(schema)}, name: {mbt_str(name)}, columns: [')
        for c in cols:
            w(f'    {c},')
        w('  ] },')
    # Hand-written descriptor (cursor work, commit 59e22ac): the DMV is read
    # as a table function and has no `SELECT * ... WHERE 1 = 0` capture.
    w(EXTRA_VIEWS.rstrip('\n'))
    w(']')
    w('')

    def seed_rows(key, view, cols=None):
        d = seed[key]
        names = d['columns']
        tys = types_by_view[view]
        rows = []
        for r in d['rows']:
            vals = []
            for n, v in zip(names, r):
                if cols is not None and n not in cols:
                    continue
                ty = tys[n]
                vals.append(value(v, ty))
            rows.append('[' + ', '.join(vals) + ']')
        return names, rows

    for key, view, var in [
        ('system_objects', 'sys.objects', 'seed_system_objects'),
        ('types', 'sys.types', 'seed_types'),
        ('databases', 'sys.databases', 'seed_databases'),
    ]:
        names, rows = seed_rows(key, view)
        w('///|')
        w(f'/// Columns: {", ".join(names)}')
        w(f'let {var} : Array[Array[@types.Value]] = [')
        for r in rows:
            w(f'  {r},')
        w(']')
        w('')
    w('///|')
    w(f'let seed_database_columns : Array[String] = [{", ".join(mbt_str(n) for n in seed["databases"]["columns"])}]')
    w('')
    w('///|')
    w(f'let seed_system_object_columns : Array[String] = [{", ".join(mbt_str(n) for n in seed["system_objects"]["columns"])}]')
    w('')
    w('///|')
    w(f'let seed_type_columns : Array[String] = [{", ".join(mbt_str(n) for n in seed["types"]["columns"])}]')
    scoped = json.load(open(os.path.join(CORPUS, 'sql2025/scoped-configurations.expected.json')))['steps']
    scoped_rows = scoped[0]['sets'][0]['rows']
    scoped_types = scoped[1]['sets'][0]['rows']
    w('')
    w('///|')
    w('// Captured defaults; mutable settings are overlaid by view_rows.')
    w('let seed_scoped_configurations : Array[Array[@types.Value]] = [')
    for row, props in zip(scoped_rows, scoped_types):
        assert row[0] == props[0] and row[3] is None
        ty = {'int': 'Int', 'bit': 'Bit', 'smallint': 'SmallInt'}.get(props[1])
        if props[1] == 'nvarchar':
            assert props[4] == 'SQL_Latin1_General_CP1_CI_AS'
            ty = f'NVarChar(Some({props[3] // 2}), coll_default)'
        assert ty is not None
        payload = value(row[2], ty)
        w(f'  [Int({row[0]}), String({mbt_str(row[1])}), Variant({payload}, {ty}), Null, Bit(true)],')
    w(']')
    with open(OUT, 'w') as f:
        f.write('\n'.join(out) + '\n')
    system(types_by_view)


def read_tsv(name):
    lines = open(os.path.join(SYSTEM, name)).read().rstrip('\n').split('\n')
    head = lines[0].split('\t')
    unesc = lambda v: None if v == '\\N' else v.replace('\\t', '\t').replace('\\n', '\n').replace('\\\\', '\\')
    return head, [[unesc(v) for v in l.split('\t')] for l in lines[1:]]


def units(text, base):
    d = datetime.fromisoformat(text)
    days = (d.date() - base).days
    secs = d.hour * 3600 + d.minute * 60 + d.second + d.microsecond / 1e6
    return days * 25920000 + round(secs * 300)


def system(types_by_view):
    """sysviews_system_data.mbt: sys.system_objects, sys.system_columns and
    sys.server_principals rows (scripts/system-catalog/*.tsv, dumped by
    harness/src/dump-system-catalog.mjs). Objects and columns are compact
    text parsed on first use (session/system_catalog.mbt)."""
    out = []
    w = out.append
    w('// Generated by scripts/gen-sysviews.py from scripts/system-catalog/*.tsv')
    w('// (dumped from the oracle by harness/src/dump-system-catalog.mjs).')
    w('// Do not edit by hand.')
    w('')
    _, objs = read_tsv('system_objects.tsv')
    base = min(datetime.fromisoformat(r[5]).date() for r in objs)
    descs = {}
    for r in objs:
        assert '|' not in r[0]
        if descs.setdefault(r[3], r[4]) != r[4]:
            raise SystemExit(f'type {r[3]} has two descriptions')
    w('///|')
    w('/// Day (since 1900-01-01) that system object dates count from.')
    w(f'let system_objects_base_day : Int = {(base - datetime(1900, 1, 1).date()).days}')
    w('')
    w('///|')
    w('/// type code -> type_desc of system objects.')
    w('let system_object_descs : Array[(String, String)] = [')
    for k, v in sorted(descs.items()):
        w(f'  ({mbt_str(k)}, {mbt_str(v)}),')
    w(']')
    w('')
    w('///|')
    w('/// sys.system_objects: name|object_id|schema_id|type|create|modify, dates')
    w('/// in datetime units (1/300 s) since the base day.')
    w('let system_objects_text : String =')
    for r in objs:
        w(f'  #|{r[0]}|{r[1]}|{r[2]}|{r[3]}|{units(r[5], base)}|{units(r[6], base)}')
    w('')
    _, cols = read_tsv('system_columns.tsv')
    combos = {}
    for r in cols:
        combos.setdefault(tuple(r[3:9]), len(combos))
    w('///|')
    w('/// (system_type_id, user_type_id, max_length, precision, scale, collation')
    w('/// or "") combinations of system columns.')
    w('let system_column_types : Array[(Int, Int, Int, Int, Int, String)] = [')
    for k in combos:
        w(f'  ({k[0]}, {k[1]}, {k[2]}, {k[3]}, {k[4]}, {mbt_str(k[5] or "")}),')
    w(']')
    w('')
    w('///|')
    w('/// sys.system_columns: `@object_id` lines, then one line per column in')
    w('/// column_id order: name|type index|is_nullable + 2 * is_ansi_padded.')
    w('let system_columns_text : String =')
    prev = None
    for r in cols:
        assert '|' not in r[1] and not r[1].startswith('@')
        if r[0] != prev:
            w(f'  #|@{r[0]}')
            prev = r[0]
        w(f'  #|{r[1]}|{combos[tuple(r[3:9])]}|{int(r[9]) + 2 * int(r[10])}')
    w('')
    head, princ = read_tsv('server_principals.tsv')
    tys = types_by_view['sys.server_principals']
    w('///|')
    w(f'/// sys.server_principals. Columns: {", ".join(head)}')
    w('let seed_server_principals : Array[Array[@types.Value]] = [')
    for r in princ:
        vals = []
        for n, v in zip(head, r):
            ty = tys[n]
            if v is None:
                vals.append('Null')
            elif ty.startswith('VarBinary'):
                vals.append('Binary(b"' + ''.join(f'\\x{v[i:i+2].lower()}' for i in range(0, len(v), 2)) + '")')
            elif ty in ('Bit', 'TinyInt', 'SmallInt', 'Int', 'BigInt'):
                vals.append(value(int(v), ty))
            else:
                vals.append(value(v, ty))
        w('  [' + ', '.join(vals) + '],')
    w(']')
    w('')
    w('///|')
    w(f'let seed_server_principal_columns : Array[String] = [{", ".join(mbt_str(n) for n in head)}]')
    with open(OUT_SYSTEM, 'w') as f:
        f.write('\n'.join(out) + '\n')


main()
