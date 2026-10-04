// Generates src/core/exec/culture_data.mbt: the .NET culture data FORMAT and
// PARSE need (number/currency/percent symbols and patterns, month and day
// names, standard date/time patterns), read back from the oracle's own
// FORMAT output, plus the list of two-letter language codes the oracle
// knows (any other well-formed name formats like the invariant culture).
//
//   node gen/cultures.mjs            (needs the oracle: npm run oracle:start)
//
// Patterns are reconstructed by formatting probe dates and mapping each
// value back to its custom-format token (2009-01-02 03:04:05 is a Friday
// whose fields all differ; 15:04:05 separates HH from hh). Cultures whose
// FORMAT year is not the Gregorian one are marked with their calendar
// (Thai Buddhist: +543 years) or as unsupported (Hijri).
import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { capture } from '../src/capture-core.mjs'
import { connect, close } from '../src/client.mjs'
import { startOracle } from '../src/oracle.mjs'

process.env.TZ = 'UTC'
const repo = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const outFile = join(repo, 'src', 'core', 'exec', 'culture_data.mbt')

// specific cultures of sys.syslanguages, a few common ones, and neutrals
const cultures = [
  'iv', 'en-US', 'en-GB', 'de-DE', 'fr-FR', 'ja-JP', 'zh-TW', 'zh-CN', 'ko-KR', 'ar-SA', 'th-TH',
  'es-ES', 'it-IT', 'nl-NL', 'nb-NO', 'nn-NO', 'pt-PT', 'pt-BR', 'fi-FI', 'sv-SE', 'da-DK', 'cs-CZ',
  'hu-HU', 'pl-PL', 'ro-RO', 'hr-HR', 'sk-SK', 'sl-SI', 'el-GR', 'bg-BG', 'ru-RU', 'tr-TR', 'et-EE',
  'lv-LV', 'lt-LT', 'de-AT', 'de-CH', 'fr-CA', 'fr-CH', 'fr-BE', 'en-CA', 'en-AU', 'en-IE', 'en-NZ',
  'es-MX', 'nl-BE', 'uk-UA', 'he-IL', 'hi-IN',
  'en', 'de', 'fr', 'ja', 'es', 'it', 'nl', 'pt', 'ru', 'pl', 'sv', 'da', 'fi', 'cs', 'ko', 'zh', 'ar', 'tr',
]

const { config } = await startOracle({ log: t => process.stderr.write(t) })
const conn = await connect(config)
const q = async sql => {
  for (let attempt = 0; ; attempt++) {
    try {
      const r = await capture(conn, { kind: 'batch', sql })
      if (r.errors.length) return { error: r.errors[0] }
      return { row: r.sets[0].rows[0] }
    } catch (e) { if (attempt > 3) throw e }
  }
}
const lit = s => `N'${s.replace(/'/g, "''")}'`
async function formats(exprs, c) {
  const r = await q(`SELECT ${exprs.map(e => `FORMAT(${e[0]}, ${lit(e[1])}, ${lit(c)})`).join(', ')}`)
  if (r.error) throw new Error(`${c}: ${r.error.message}`)
  return r.row
}

// number body analysis: digits with separators
function body(s) {
  const i = s.search(/[0-9]/)
  let j = s.length - 1
  while (j >= 0 && !/[0-9]/.test(s[j])) j--
  return { pre: s.slice(0, i), core: s.slice(i, j + 1), post: s.slice(j + 1) }
}
function separators(core, fracDigits) {
  // core like 1,234,567.125 : the decimal separator precedes the last fracDigits digits
  const frac = core.slice(core.length - fracDigits)
  const intPart = core.slice(0, core.length - fracDigits)
  let k = intPart.length - 1
  while (k >= 0 && !/[0-9]/.test(intPart[k])) k--
  const dec = intPart.slice(k + 1)
  const ip = intPart.slice(0, k + 1)
  const runs = ip.split(/[^0-9]+/)
  const group = (ip.match(/[^0-9]+/) ?? [''])[0]
  const sizes = []
  for (let r = runs.length - 1; r > 0; r--) sizes.push(runs[r].length)
  // collapse a repeating tail: [3,3] -> [3], [3,2,2] -> [3,2]
  while (sizes.length > 1 && sizes[sizes.length - 1] === sizes[sizes.length - 2]) sizes.pop()
  if (frac !== '125') throw new Error(`unexpected fraction ${core}`)
  return { dec, group, sizes: sizes.length ? sizes : [3] }
}
function template(s, decSep) {
  const needle = `1${decSep}5`
  if (!s.includes(needle)) throw new Error(`no ${needle} in ${s}`)
  return s.replace(needle, '#')
}

async function numberData(c) {
  const [n3, nn, nd, c3, cp, cn, cd, p3, pp, pn, pd, sign, pct, pm] = await formats([
    ['CAST(1234567.125 AS decimal(10,3))', 'N3'], ['CAST(-1.5 AS decimal(5,1))', 'N1'], ['CAST(1.5 AS decimal(5,1))', 'N'],
    ['CAST(1234567.125 AS decimal(10,3))', 'C3'], ['CAST(1.5 AS decimal(5,1))', 'C1'], ['CAST(-1.5 AS decimal(5,1))', 'C1'], ['CAST(1.5 AS decimal(5,1))', 'C'],
    ['CAST(12345.67125 AS decimal(10,5))', 'P3'], ['CAST(0.015 AS decimal(5,3))', 'P1'], ['CAST(-0.015 AS decimal(5,3))', 'P1'], ['CAST(0.5 AS decimal(5,1))', 'P'],
    ['CAST(-1.5 AS decimal(5,1))', '0.0'], ['CAST(0.5 AS decimal(5,1))', '0%'], ['CAST(0.5 AS decimal(5,1))', '0‰'],
  ], c)
  const ns = separators(body(n3).core, 3)
  const cs = separators(body(c3).core, 3)
  const ps = separators(body(p3).core, 3)
  const digitsAfter = (s, dec) => { const b = body(s).core; const i = b.lastIndexOf(dec); return dec && i >= 0 ? b.length - i - dec.length : 0 }
  const cpb = body(cp)
  return {
    nDec: ns.dec, nGroup: ns.group, nSizes: ns.sizes, nNeg: template(nn, ns.dec), nDigits: digitsAfter(nd, ns.dec),
    cDec: cs.dec, cGroup: cs.group, cSizes: cs.sizes, cPos: template(cp, cs.dec), cNeg: template(cn, cs.dec), cDigits: digitsAfter(cd, cs.dec),
    cSymbol: (cpb.pre + cpb.post).trim(),
    pDec: ps.dec, pGroup: ps.group, pSizes: ps.sizes, pPos: template(pp, ps.dec), pNeg: template(pn, ps.dec), pDigits: digitsAfter(pd, ps.dec),
    negSign: sign.slice(0, sign.indexOf('1')), percent: pct.slice(pct.indexOf('50') + 2), permille: pm.slice(pm.indexOf('500') + 3),
  }
}

const d = (y, m, day, h = 0, mi = 0, s = 0) => `CAST('${y}-${String(m).padStart(2, '0')}-${String(day).padStart(2, '0')}T${String(h).padStart(2, '0')}:${String(mi).padStart(2, '0')}:${String(s).padStart(2, '0')}' AS datetime2(0))`
async function dateData(c) {
  const [year] = await formats([[d(2009, 1, 2), 'yyyy']], c)
  const calendar = year === '2009' ? 0 : year === '2552' ? 1 : 2
  const months = await formats(Array.from({ length: 12 }, (_, i) => [d(2024, i + 1, 15), 'MMMM']), c)
  const monthsAbbr = await formats(Array.from({ length: 12 }, (_, i) => [d(2024, i + 1, 15), 'MMM']), c)
  const monthsGen = (await formats(Array.from({ length: 12 }, (_, i) => [d(2024, i + 1, 15), 'd MMMM']), c)).map(s => s.replace(/^15 /, ''))
  const monthsAbbrGen = (await formats(Array.from({ length: 12 }, (_, i) => [d(2024, i + 1, 15), 'd MMM']), c)).map(s => s.replace(/^15 /, ''))
  // 2024-03-03 is a Sunday
  const days = await formats(Array.from({ length: 7 }, (_, i) => [d(2024, 3, 3 + i), 'dddd']), c)
  const daysAbbr = await formats(Array.from({ length: 7 }, (_, i) => [d(2024, 3, 3 + i), 'ddd']), c)
  const [am, pm, dsep, tsep] = await formats([[d(2024, 1, 1, 1), 'tt'], [d(2024, 1, 1, 13), 'tt'], [d(2024, 1, 1), 'yyyy/MM/dd'], [d(2024, 1, 1, 1, 2), 'HH:mm']], c)
  const std = ['d', 'D', 't', 'T', 'f', 'F', 'g', 'G', 'M', 'Y']
  const pats = {}
  if (calendar !== 2) {
    const morning = await formats(std.map(f => [d(2009, 1, 2, 3, 4, 5), f]), c)
    const evening = await formats(std.map(f => [d(2009, 1, 2, 15, 4, 5), f]), c)
    const y = calendar === 1 ? '2552' : '2009'
    std.forEach((f, i) => { pats[f] = pattern(morning[i], evening[i], { y, months, monthsAbbr, monthsGen, monthsAbbrGen, days, daysAbbr, am, pm }) })
  }
  return {
    calendar, months, monthsAbbr, monthsGen, monthsAbbrGen, days, daysAbbr, am, pm,
    dateSep: dsep.slice(4, dsep.length - 5), timeSep: tsep.slice(2, tsep.length - 2), pats,
  }
}

// map a formatted probe (2009-01-02 03:04:05 Friday, and 15:04:05) back to tokens
function pattern(s, e, k) {
  const out = []
  let lit = ''
  const flush = () => { if (lit) { out.push(`'${lit.replace(/'/g, "\\'")}'`); lit = '' } }
  const tok = t => { flush(); out.push(t) }
  let i = 0
  let j = 0 // position in the evening string
  const cands = [
    [k.days[5], 'dddd'], [k.daysAbbr[5], 'ddd'],
    [k.monthsGen[0], 'MMMM'], [k.months[0], 'MMMM'], [k.monthsAbbrGen[0], 'MMM'], [k.monthsAbbr[0], 'MMM'],
    [k.y, 'yyyy'], [k.y.slice(2), 'yy'], ['01', 'MM'], ['02', 'dd'], ['03', 'hh'], ['04', 'mm'], ['05', 'ss'],
    ['1', 'M'], ['2', 'd'], ['3', 'h'], ['4', 'm'], ['5', 's'],
  ].filter(([v]) => v).sort((a, b) => b[0].length - a[0].length)
  while (i < s.length) {
    if (k.am && s.startsWith(k.am, i) && e.startsWith(k.pm, j)) { tok('tt'); i += k.am.length; j += k.pm.length; continue }
    const m = cands.find(([v]) => s.startsWith(v, i))
    if (m) {
      let t = m[1]
      let elen = m[0].length
      if (t === 'hh' || t === 'h') {
        if (e.startsWith('15', j)) { t = t === 'hh' ? 'HH' : 'H'; elen = 2 }
        else if (t === 'h' && e.startsWith('3', j)) elen = 1
      }
      tok(t); i += m[0].length; j += elen; continue
    }
    lit += s[i]; i++; j++
  }
  flush()
  return out.join('')
}

async function languages() {
  const inv = await formats([[d(2024, 3, 5), 'D'], ['CAST(-1234.5 AS decimal(6,1))', 'C'], [d(2024, 3, 5, 14), 'F']], 'iv')
  const known = []
  const letters = 'abcdefghijklmnopqrstuvwxyz'
  for (const a of letters) for (const b of letters) {
    const c = a + b
    const r = await q(`SELECT FORMAT(${d(2024, 3, 5)}, 'D', '${c}'), FORMAT(CAST(-1234.5 AS decimal(6,1)), 'C', '${c}'), FORMAT(${d(2024, 3, 5, 14)}, 'F', '${c}')`)
    if (r.error) continue
    if (r.row.some((v, i) => v !== inv[i])) known.push(c)
  }
  return known
}

const data = []
for (const c of cultures) {
  process.stderr.write(`${c} `)
  data.push({ name: c, ...await numberData(c), ...await dateData(c) })
}
process.stderr.write('\nlanguages ')
const known = await languages()
process.stderr.write(`${known.length}\n`)
await close(conn)

const str = s => JSON.stringify(s).replace(/[\u007f-￿]/g, ch => `\\u{${ch.charCodeAt(0).toString(16)}}`)
const arr = a => `[${a.map(v => typeof v === 'number' ? String(v) : str(v)).join(', ')}]`
const lines = [
  '// Generated by harness/gen/cultures.mjs from SQL Server 17.0.5005 FORMAT',
  '// output (.NET culture data). Do not edit by hand: regenerate.',
  '',
  '///|',
  'let culture_table : Array[CultureData] = [',
]
for (const x of data) {
  const p = x.pats
  lines.push('  {', `    name: ${str(x.name)},`,
    `    n_dec: ${str(x.nDec)}, n_group: ${str(x.nGroup)}, n_sizes: ${arr(x.nSizes)}, n_neg: ${str(x.nNeg)}, n_digits: ${x.nDigits},`,
    `    c_symbol: ${str(x.cSymbol)}, c_dec: ${str(x.cDec)}, c_group: ${str(x.cGroup)}, c_sizes: ${arr(x.cSizes)}, c_pos: ${str(x.cPos)}, c_neg: ${str(x.cNeg)}, c_digits: ${x.cDigits},`,
    `    p_dec: ${str(x.pDec)}, p_group: ${str(x.pGroup)}, p_sizes: ${arr(x.pSizes)}, p_pos: ${str(x.pPos)}, p_neg: ${str(x.pNeg)}, p_digits: ${x.pDigits},`,
    `    neg_sign: ${str(x.negSign)}, percent: ${str(x.percent)}, permille: ${str(x.permille)},`,
    `    calendar: ${x.calendar},`,
    `    months: ${arr(x.months)},`, `    months_abbr: ${arr(x.monthsAbbr)},`,
    `    months_gen: ${arr(x.monthsGen)},`, `    months_abbr_gen: ${arr(x.monthsAbbrGen)},`,
    `    days: ${arr(x.days)},`, `    days_abbr: ${arr(x.daysAbbr)},`,
    `    am: ${str(x.am)}, pm: ${str(x.pm)}, date_sep: ${str(x.dateSep)}, time_sep: ${str(x.timeSep)},`,
    `    pat_d: ${str(p.d ?? '')}, pat_long_d: ${str(p.D ?? '')}, pat_t: ${str(p.t ?? '')}, pat_long_t: ${str(p.T ?? '')},`,
    `    pat_f: ${str(p.f ?? '')}, pat_long_f: ${str(p.F ?? '')}, pat_g: ${str(p.g ?? '')}, pat_long_g: ${str(p.G ?? '')},`,
    `    pat_m: ${str(p.M ?? '')}, pat_y: ${str(p.Y ?? '')},`,
    '  },')
}
lines.push(']', '', '///|', '/// Two-letter language codes with their own culture data on the oracle.', `let known_languages : Array[String] = ${arr(known)}`, '')
writeFileSync(outFile, lines.join('\n'))
console.log(`wrote ${outFile}: ${data.length} cultures, ${known.length} known languages`)
