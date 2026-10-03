// Shared paths and process setup for every harness entry point.
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const harnessDir = resolve(dirname(fileURLToPath(import.meta.url)), '..')
export const repoDir = resolve(harnessDir, '..')
export const corpusDir = resolve(harnessDir, 'corpus')
export const outDir = resolve(harnessDir, 'out')

// tedious derives bound DATETIMEOFFSET/Date parameter offsets from the client
// process time zone (msduck finding). Force UTC before any Date is created.
export function useUtcTimeZone(env = process.env) {
  env.TZ = 'UTC'
  if (env === process.env && new Date(0).getTimezoneOffset() !== 0) throw new Error('could not switch the process time zone to UTC')
}

// Minimal argv parser: --flag, --key value, --key=value, positionals.
export function parseArgs(argv, { booleans = [] } = {}) {
  const flags = {}
  const positionals = []
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (!arg.startsWith('--')) { positionals.push(arg); continue }
    const eq = arg.indexOf('=')
    if (eq > 0) { flags[arg.slice(2, eq)] = arg.slice(eq + 1); continue }
    const name = arg.slice(2)
    if (booleans.includes(name) || i + 1 >= argv.length || argv[i + 1].startsWith('--')) flags[name] = true
    else flags[name] = argv[++i]
  }
  return { flags, positionals }
}
