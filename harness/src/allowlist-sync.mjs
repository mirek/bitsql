// npm run allowlist:sync [-- <header text>]
// Appends every case that passed in the last `npm run diff` (out/report.json)
// and is not yet in allowlist.txt, under a dated comment header, so `npm test`
// guards it from now on. Run a full diff first (all corpus areas).
import { readFile, appendFile } from 'node:fs/promises'
import { join } from 'node:path'
import { harnessDir } from './env.mjs'

const report = JSON.parse(await readFile(join(harnessDir, 'out/report.json'), 'utf8'))
const path = join(harnessDir, 'allowlist.txt')
const have = new Set((await readFile(path, 'utf8')).split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#')))
// report ids: `area/name` (.sql) or `area/file#case` (.cases.json)
const selector = id => id.includes('#') ? id.replace('#', '.cases.json#') : `${id}.sql`
const added = report.passed.map(selector).filter(s => !have.has(s)).sort()
if (added.length) {
  const header = process.argv.slice(2).join(' ') || 'newly passing'
  await appendFile(path, `# ${new Date().toISOString().slice(0, 10)}: ${header}\n${added.join('\n')}\n`)
}
console.log(`allowlist: +${added.length} (${have.size + added.length} total)`)
