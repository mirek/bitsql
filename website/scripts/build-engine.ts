import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../../', import.meta.url));
execFileSync('moon', ['build', '--target', 'js', '--release', '--deny-warn', 'src/browser'], { cwd: root, stdio: 'inherit' });
const generated = new URL('../src/generated/', import.meta.url);
mkdirSync(generated, { recursive: true });
copyFileSync(new URL('../../_build/js/release/build/browser/browser.js', import.meta.url), new URL('engine.js', generated));
