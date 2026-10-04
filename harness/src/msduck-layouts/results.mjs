// msduck layout adapters: `results` / `cases` / misc layouts (see project.mjs
// for the Run/Entry shape). Keys are msduck reference file base names.
// Semantics per file come from msduck scripts/capture-<name>.mjs.
import { customExpect, projectLike, scrub, slug, standardExpect, tediousParam } from './project.mjs'

// Some files were captured in master (no fresh database); the harness runs
// in a case database, so 'master.dbo.' in messages becomes '{db}.dbo.'.
const masterToDb = doc => JSON.parse(JSON.stringify(doc).replace(/\bmaster\.(?=dbo\.)/g, '{db}.').replace(/database \\"master\\"/g, 'database \\"{db}\\"'))

const VERSION_PROBE = /SERVERPROPERTY\('ProductVersion'\)|@@VERSION/i
const versionSkip = name => ({ name, skip: 'server version probe', stateless: true })

// msduck DONE tokens ({name, handlerName, more, sqlError, attention,
// serverError, rowCount?, curCmd}) next to a standard capture.
const stripTokens = tokens => tokens.map(({ handlerName, ...t }) => t)
function withTokens(result, tokens) {
  const std = standardExpect(result)
  if (!tokens) return std
  const value = { ...std.value, tokens: scrub(stripTokens(tokens)) }
  return { value, project: actual => ({ ...std.project(actual), tokens: projectLike(actual.tokens, value.tokens) }) }
}

// msduck orderedCapture `events`: [{kind:'metadata'|'row'|'info'|'error'|done kinds}]
// rebuilt from bitsql's stream (DONE row counts from `done` in order).
function eventsOf(actual) {
  const events = []
  let d = 0
  for (const t of actual.stream ?? []) {
    if (t.name === 'COLMETADATA') events.push({ kind: 'metadata' })
    else if (t.name === 'ROW' || t.name === 'NBCROW') for (let i = 0; i < t.count; i++) events.push({ kind: 'row' })
    else if (t.name === 'INFO') events.push({ kind: 'info', number: t.number })
    else if (t.name === 'ERROR') events.push({ kind: 'error', number: t.number })
    else if (/^DONE/.test(t.name)) { const x = actual.done[d++]; events.push({ kind: x?.kind, rowCount: x?.rowCount ?? null, more: x?.more }) }
  }
  return events
}
function withEvents(result) {
  const { events, ...rest } = result
  const std = standardExpect(rest)
  if (!events) return std
  const value = { ...std.value, events: scrub(events) }
  return { value, project: actual => ({ ...std.project(actual), events: eventsOf(actual) }) }
}

const batch = (sql, result, expectFn = standardExpect) => ({ kind: 'batch', sql, ...(result ? { expect: expectFn(result) } : {}) })
const setupOnly = (name, sqls) => ({ name, steps: sqls.map(sql => ({ kind: 'batch', sql })) })

// [{name, sql, parameters?: [{name,type,value,options}], result}] on one connection.
function namedSequence(doc, id = 'run') {
  return [{
    id,
    entries: doc.results.map(r => {
      if (VERSION_PROBE.test(r.sql) && /version/i.test(r.name)) return versionSkip(r.name)
      const params = r.parameters?.map(p => tediousParam([p.name, p.type, p.value, p.options]))
      return { name: r.name, steps: [{ kind: params ? 'rpc' : 'batch', sql: r.sql, ...(params ? { params } : {}), expect: standardExpect(r.result) }] }
    }),
  }]
}

// [{name, session, mode?, sql, result}]: only the primary session can be
// replayed on one connection. Other sessions are skipped (stateless: their
// effects on the primary, if any, make the msduck comparison reject the case).
function sessionSequence(results, { primary, skipEntry = () => null } = {}) {
  const first = primary ?? results.find(r => r.session)?.session
  return [{
    id: 'run',
    entries: results.map(r => {
      const special = skipEntry(r)
      if (special) return { name: r.name, ...special }
      if (r.session !== first) return { name: r.name, skip: `multi-connection (session ${r.session ?? 'none'})`, stateless: true }
      if ((r.sql === undefined || r.sql === '') && /version/i.test(r.name)) return versionSkip(r.name)
      if (r.sql === undefined || r.sql === '') return { name: r.name, skip: 'no SQL recorded' }
      if (VERSION_PROBE.test(r.sql) && /version/i.test(r.name)) return versionSkip(r.name)
      const kind = r.mode === 'rpc' ? 'rpc' : 'batch'
      return { name: r.name, steps: [{ kind, sql: r.sql, expect: standardExpect(r.result) }] }
    }),
  }]
}

// Groups of {setup, operations:[{operation, sql, result}]} on one connection:
// each group is its own run (setup entry, then one entry per operation).
const groupRun = (id, setup, operations, nameOf = o => o.operation) => ({
  id,
  entries: [setupOnly(`${id} setup`, [].concat(setup)), ...operations.map(o => ({ name: `${id} ${nameOf(o)}`, steps: [batch(o.sql, o.result)] }))],
})

const adapters = {
  // results: [{id, mode: ON|OFF, sql, result+events}]; one connection, each
  // entry preceded by SET ANSI_WARNINGS <mode>; entries are independent.
  'aggregate-warnings': doc => [{
    id: 'run', independent: true,
    entries: doc.results.map(r => ({ name: r.id, steps: [{ kind: 'batch', sql: `SET ANSI_WARNINGS ${r.mode}` }, batch(r.sql, r.result, withEvents)] })),
  }],

  // results: [{id, mode, setup[], sql, followup, executions:[{result, state, contents}]}]
  // Each entry: reset/setup batches, SET ANSI_WARNINGS, then per execution
  // the statement, a state probe and a contents query (all compared).
  'aggregate-warning-boundaries': doc => (doc = masterToDb(doc), [{
    id: 'run', independent: true,
    entries: doc.results.map(r => ({
      name: r.id,
      steps: [
        ...r.setup.map(sql => ({ kind: 'batch', sql })),
        { kind: 'batch', sql: `SET ANSI_WARNINGS ${r.mode}` },
        ...r.executions.flatMap(e => [
          batch(r.sql, e.result, withEvents),
          batch('SELECT @@ERROR AS last_error,@@ROWCOUNT AS last_rowcount,@@TRANCOUNT AS transaction_count,XACT_STATE() AS transaction_state', e.state, withEvents),
          batch(r.followup, e.contents, withEvents),
        ]),
      ],
    })),
  }]),

  // cases: [{name, setup[], query, result:{sets:[{columns:[[name,type,length]],rows}], errors, done:[rowCount]}}]
  // fresh database per case; result keeps a reduced projection.
  'apply-full-join': doc => [{
    id: 'run', independent: true,
    entries: doc.cases.map(c => ({
      name: c.name,
      steps: [
        ...c.setup.map(sql => ({ kind: 'batch', sql })),
        {
          kind: 'batch', sql: c.query,
          expect: customExpect(c.result, a => ({
            sets: a.sets.map(s => ({ columns: s.columns.map(x => [x.name, x.type, x.length]), rows: s.rows })),
            errors: a.errors.map(e => ({ number: e.number, class: e.class ?? null, state: e.state ?? null, message: e.message })),
            done: a.done.filter(d => d.kind === 'done' || d.kind === 'doneInProc').map(d => d.rowCount),
          })),
        },
      ],
    })),
  }],

  // Same layout and projection as apply-full-join (issue #900: ISNULL /
  // COALESCE / IIF over OPENJSON values); fresh database per case.
  'openjson-isnull': doc => adapters['apply-full-join'](doc),

  // cases: [{group, name, sql, sets:[{columns:[{name,type,length,collation}],
  // rows}], errors:[{number,state,class,message}]}]: one batch each in one
  // database, every table dropped after each case (independent).
  'default-collation': doc => [{
    id: 'run', independent: true,
    entries: doc.cases.map(c => ({
      name: `${c.group} ${c.name}`,
      steps: [{
        kind: 'batch', sql: c.sql,
        expect: customExpect({ sets: c.sets, errors: c.errors }, a => ({
          sets: a.sets.map(s => ({
            columns: s.columns.map(x => ({ name: x.name, type: x.type, length: x.length ?? null, collation: x.collation ?? null })),
            rows: s.rows,
          })),
          errors: a.errors.map(e => ({ number: e.number, state: e.state, class: e.class, message: e.message })),
        })),
      }],
    })),
  }],

  // cases: [{width, operation, left, right, sql, result}] on one connection
  // after SET ARITHABORT ON; SET ANSI_WARNINGS ON; queries are independent.
  'checked-integer': doc => [{
    id: 'run', independent: true,
    entries: doc.cases.map(c => ({
      name: `${c.leftWidth ?? c.width}${c.rightWidth ? `-${c.rightWidth}` : ''} ${c.operation} ${c.left} ${c.right}`,
      steps: [{ kind: 'batch', sql: 'SET ARITHABORT ON; SET ANSI_WARNINGS ON' }, batch(c.sql, c.result)],
    })),
  }],

  // results: [{name, sql, parameters?, result}] sequentially on one connection.
  'dateadd-legacy': doc => namedSequence(doc),
  'datediff-numeric': doc => namedSequence(doc),

  // results: [{name, sql, session: A|B, result}]; B is a second connection.
  dateformat: doc => sessionSequence(doc.results, { primary: 'A' }),

  // results: [{name, sql, session: A|B, result}]; B is a second connection.
  'sequence-reference': doc => sessionSequence(doc.results, { primary: 'A' }),

  // results: [{name, session: primary|secondary|undefined, sql?, result}].
  // Prepared-handle steps (no SQL) and the resetConnection (skiptran) request
  // cannot be expressed; the reset changes all later primary state.
  'session-reset-skiptran': doc => sessionSequence(doc.results, {
    primary: 'primary',
    skipEntry: r => r.session === undefined ? { skip: 'session reset (resetConnection) request' }
      : (r.session === 'primary' && !r.sql) ? { skip: 'prepared protocol (sp_prepare/sp_execute)', stateless: true } : null,
  }),

  // results: [{name, session: A|B|C, mode, sql?, result}]; C is a new
  // connection after closing A. Global temp tables (##) are shared across
  // concurrently verified cases on the oracle, so those entries are skipped.
  'temp-table-scope': doc => sessionSequence(doc.results, {
    primary: 'A',
    skipEntry: r => r.session === 'C' ? { skip: 'reconnect (new connection)', stateless: true }
      : r.sql?.includes('##') ? { skip: 'global temp table (shared across concurrent cases)', stateless: true } : null,
  }),

  // results: [{mode: batch|rpc, results:[{id, sql, result, completion, state}]}]
  // One fresh database per mode; in rpc mode every request (also the state
  // probe) is sp_executesql.
  'ddl-completion': doc => doc.results.map(suite => {
    const kind = suite.mode === 'rpc' ? 'rpc' : 'batch'
    return {
      id: suite.mode,
      entries: suite.results.map(r => ({
        name: `${suite.mode} ${r.id}`,
        steps: [
          { kind, sql: r.sql, expect: withTokens(r.result, r.completion) },
          { kind, sql: 'SELECT @@ROWCOUNT AS r,@@ERROR AS e', expect: standardExpect(r.state) },
        ],
      })),
    }
  }),

  // setup[], inventory; results: [{id, sql, result, completion, state, remaining}],
  // each in a fresh database after the setup.
  'drop-index': doc => [{
    id: 'run', independent: true,
    entries: doc.results.map(r => ({
      name: r.id,
      steps: [
        ...doc.setup.map(sql => ({ kind: 'batch', sql })),
        { kind: 'batch', sql: r.sql, expect: withTokens(r.result, r.completion) },
        batch('SELECT @@ROWCOUNT AS r,@@ERROR AS e', r.state),
        batch(doc.inventory, r.remaining),
      ],
    })),
  }],

  // results: [{id, sql, result, completion, state, indexes, columns}] in one
  // database, sequentially; declarations: independent catalog descriptor queries.
  'index-catalog': doc => [
    {
      id: 'run',
      entries: doc.results.map(r => ({
        name: r.id,
        steps: [
          { kind: 'batch', sql: r.sql, expect: withTokens(r.result, r.completion) },
          batch('SELECT @@ROWCOUNT AS r,@@ERROR AS e,@@TRANCOUNT AS t', r.state),
          batch(doc.indexSql, r.indexes),
          batch(doc.columnSql, r.columns),
        ],
      })),
    },
    {
      id: 'declarations', independent: true,
      entries: Object.entries(doc.declarations).map(([view, d]) => ({ name: `declarations ${view}`, steps: [batch(d.sql, d.result), batch(d.wireSql, d.wire)] })),
    },
  ],

  // setup[]; results (catalog width queries + per-view value queries),
  // declarations, then lob programs, all on one connection.
  'object-catalog-width': doc => [{
    id: 'run',
    entries: [
      setupOnly('setup', doc.setup),
      ...doc.results.map((r, i) => ({ name: `query ${i}`, steps: [batch(r.sql, r.result)] })),
      ...doc.declarations.map(d => ({ name: `declarations ${d.view}`, steps: [batch(d.sql, d.result)] })),
      ...doc.lob.flatMap(l => l.results.map((r, i) => ({ name: `lob ${l.name} ${i}`, steps: [batch(r.sql, r.result)] }))),
    ],
  }],

  // results: [{name, steps:[{mode, sql, parameters?, result}]}]: every case
  // starts with a baseline reset batch, so cases are independent. RPC
  // parameters are Int. prepared: sp_prepare handles, skipped.
  'rpc-session-scope': (doc, { skip }) => {
    skip('prepared protocol (sp_prepare/sp_execute)', doc.prepared?.length ?? 0)
    return [{
      id: 'run', independent: true,
      entries: doc.results.map(c => ({
        name: c.name,
        steps: c.steps.map(s => ({
          kind: s.mode === 'rpc' ? 'rpc' : 'batch', sql: s.sql,
          ...(s.parameters ? { params: Object.entries(s.parameters).map(([name, value]) => ({ name, type: 'int', value })) } : {}),
          expect: standardExpect(s.result),
        })),
      })),
    }]
  },

  // results: [{id, sql, result}] sequentially on one connection.
  'view-execution': doc => [{ id: 'run', entries: doc.results.map(r => ({ name: r.id, steps: [batch(r.sql, r.result)] })) }],
  'view-invalid-binding': doc => [{ id: 'run', entries: doc.results.map(r => ({ name: r.id, steps: [batch(r.sql, r.result)] })) }],
  'view-properties': doc => [{ id: 'run', entries: doc.results.map(r => ({ name: r.id, steps: [batch(r.sql, r.result)] })) }],

  // results: [{declaration, collation, setup, operations}]: per group a
  // table rebuilt by `setup`, then read-only operations.
  'character-extrema': doc => doc.results.map(r => groupRun(slug(`${r.declaration} ${r.collation ?? 'default'}`), r.setup, r.operations)),

  // results: [{sample, expression, setup, source, operations:[{target, mode, sql, result}]}]
  'unicode-integer': doc => doc.results.map(r => groupRun(
    slug(r.sample), r.setup, [{ operation: 'source', ...r.source }, ...r.operations], o => o.target ? `${o.mode} ${o.target}` : o.operation)),

  // results/escaped/keys: groups of {setup, operations}; nullPaths: {setup, sql, result}.
  // escaped/keys/nullPaths UPDATE the table the last `results` group created.
  // The post-reconnect re-read of each results group is not representable
  // and is not part of the expectations (it equals the pre-reconnect read).
  'unicode-json-storage': doc => {
    const tableSetup = doc.results.at(-1).setup
    return [
      ...doc.results.map(r => groupRun(slug(`${r.type} ${r.sample}`), r.setup, r.operations)),
      ...doc.escaped.map(r => groupRun(slug(`escaped ${r.sample}`), [tableSetup, r.setup], r.operations)),
      ...doc.keys.map(r => groupRun(slug(`key ${r.sample}`), [tableSetup, r.setup], r.operations)),
      {
        id: 'null-paths', independent: true,
        entries: doc.nullPaths.map(n => ({
          name: `null path ${n.source} ${n.path} ${n.operation}`,
          steps: [{ kind: 'batch', sql: tableSetup }, { kind: 'batch', sql: n.setup }, batch(n.sql, n.result)],
        })),
      },
    ]
  },

  // results: [{type, sample, expression, operation, setup, written, beforeReconnect, afterReconnect}]:
  // setup, write, read back (with DONE tokens); afterReconnect needs a new
  // connection and is not imported.
  'unicode-storage': (doc, { skip }) => {
    doc = masterToDb(doc)
    skip('reconnect (afterReconnect read-back not representable)', doc.results.filter(r => r.afterReconnect).length)
    return [{
      id: 'run', independent: true,
      entries: doc.results.map(r => ({
        name: `${r.type} ${r.sample} ${r.operation}`,
        steps: [
          { kind: 'batch', sql: r.setup },
          { kind: 'batch', sql: r.written.query, expect: withTokens(r.written.result, r.written.tokens) },
          { kind: 'batch', sql: r.beforeReconnect.query, expect: withTokens(r.beforeReconnect.result, r.beforeReconnect.tokens) },
        ],
      })),
    }]
  },

  // results: [{collation, statisticsQuery, statistics, mappingQuery, mapping,
  // strings:[{name, query, reference}]}]: independent queries.
  'unicode-case': doc => [{
    id: 'run', independent: true,
    entries: doc.results.flatMap(r => [
      { name: `${r.collation} statistics`, steps: [batch(r.statisticsQuery, r.statistics)] },
      { name: `${r.collation} mapping`, steps: [batch(r.mappingQuery, r.mapping)] },
      ...r.strings.map(s => ({ name: `${r.collation} ${s.name}`, steps: [batch(s.query, s.reference)] })),
    ]),
  }],

  // maps: per collation the 65536-unit NVARCHAR(1) -> VARCHAR best-fit table
  // (msduck kept only its hex). Re-expressed as one STRING_AGG hex row over
  // the same #units table so the expectation stays one value; two of the six
  // (identical) collation maps are kept. probes: cast + storage pairs.
  'windows-1252-best-fit': (doc, { skip }) => {
    doc = masterToDb(doc)
    const digits = Array.from({ length: 16 }, (_, n) => `(${n})`).join(',')
    const units = `CREATE TABLE #units(unit INT NOT NULL,s NVARCHAR(1)); WITH digits AS (SELECT n FROM (VALUES ${digits}) d(n)), units AS (SELECT a.n+16*b.n+256*c.n+4096*d.n AS n FROM digits a CROSS JOIN digits b CROSS JOIN digits c CROSS JOIN digits d) INSERT INTO #units SELECT n,CONVERT(NVARCHAR(1),CONVERT(BINARY(1),n%256)+CONVERT(BINARY(1),n/256)) FROM units`
    const maps = [doc.maps[0], doc.maps.at(-1)]
    skip('sampled out', doc.maps.length - maps.length)
    return [
      {
        id: 'maps', independent: true,
        entries: maps.map(m => ({
          name: `map ${m.collation}`,
          steps: [
            { kind: 'batch', sql: units },
            {
              kind: 'batch',
              sql: `SELECT STRING_AGG(CONVERT(VARCHAR(MAX),CONVERT(VARCHAR(2),CONVERT(VARBINARY(8),CONVERT(VARCHAR(8),s COLLATE ${m.collation})),2)),'') WITHIN GROUP (ORDER BY unit) AS hex FROM #units`,
              expect: customExpect(m.hex, a => typeof a.sets?.[0]?.rows?.[0]?.[0] === 'string' ? a.sets[0].rows[0][0].toLowerCase() : a.errors),
            },
          ],
        })),
      },
      {
        id: 'probes', independent: true,
        entries: doc.probes.map(p => ({
          name: `probe ${p.sourceHex || 'empty'} ${p.declaration}`,
          steps: [
            batch(p.cast.sql, p.cast.result),
            { kind: 'batch', sql: `DROP TABLE IF EXISTS dbo.best_fit_target; CREATE TABLE dbo.best_fit_target(s ${p.declaration})` },
            batch(p.storage.sql, p.storage.result),
          ],
        })),
      },
    ]
  },

  // baseline, samples, months[{hourly, minute|null}]: independent queries.
  'at-time-zone-transitions-2024': doc => [{
    id: 'run', independent: true,
    entries: [
      { name: 'baseline', steps: [batch(doc.baseline.query, doc.baseline.reference)] },
      ...doc.samples.map((s, i) => ({ name: `sample ${i}`, steps: [batch(s.query, s.reference)] })),
      ...doc.months.flatMap(m => [
        { name: `month ${m.month} hourly`, steps: [batch(m.hourly.query, m.hourly.reference)] },
        ...(m.minute ? [{ name: `month ${m.month} minute`, steps: [batch(m.minute.query, m.minute.reference)] }] : []),
      ]),
    ],
  }],
}


export default adapters
