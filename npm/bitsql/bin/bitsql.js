#!/usr/bin/env node
'use strict'
// `npx bitsql [server options]`: runs the native server in the foreground.
const { spawnSync } = require('node:child_process')
const { binaryPath } = require('../index.js')

let bin
try { bin = binaryPath() } catch (error) { console.error(error.message); process.exit(1) }
const result = spawnSync(bin, process.argv.slice(2), { stdio: 'inherit' })
if (result.error) { console.error(`bitsql: ${result.error.message}`); process.exit(1) }
process.exit(result.status ?? 1)
