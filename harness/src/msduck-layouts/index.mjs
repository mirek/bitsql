// Registry of msduck layout adapters: { <reference file base name>: (doc, ctx) => Run[] }.
import core from './core.mjs'
import gapsA from './gaps-a.mjs'
import gapsB from './gaps-b.mjs'
import runs from './runs.mjs'
import grids from './grids.mjs'

export const adapters = {}
for (const group of [core, gapsA, gapsB, runs, grids]) {
  for (const [name, adapt] of Object.entries(group)) {
    if (adapters[name]) throw new Error(`duplicate msduck layout adapter for ${name}`)
    adapters[name] = adapt
  }
}
