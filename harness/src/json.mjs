// Reviewable, deterministic JSON: containers whose one-line form fits within
// `width` stay on one line, larger ones are expanded with 2-space indent.
import { writeFile } from 'node:fs/promises'

export function formatJson(value, width = 140, indent = '') {
  const flat = JSON.stringify(value)
  if (flat === undefined) return 'null'
  if (value === null || typeof value !== 'object' || flat.length + indent.length <= width) return flat
  const inner = indent + '  '
  if (Array.isArray(value)) {
    if (!value.length) return '[]'
    return `[\n${value.map(v => inner + formatJson(v, width, inner)).join(',\n')}\n${indent}]`
  }
  const entries = Object.entries(value).filter(([, v]) => v !== undefined)
  if (!entries.length) return '{}'
  return `{\n${entries.map(([k, v]) => `${inner}${JSON.stringify(k)}: ${formatJson(v, width, inner)}`).join(',\n')}\n${indent}}`
}

// flag 'wx' refuses to overwrite (msduck writeNewFixture); 'w' overwrites.
export async function writeJson(path, value, { overwrite = false } = {}) {
  await writeFile(path, formatJson(value) + '\n', { flag: overwrite ? 'w' : 'wx' })
}
