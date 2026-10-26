#!/usr/bin/env bash
# The `bitsql` npm package: the engine as WebAssembly GC plus the TypeScript
# host in npm/bitsql (one platform-neutral package).
#   scripts/npm-publish.sh          build, run the harness through it, pack, smoke
#   scripts/npm-publish.sh --push   also publish (npm login first)
# The fidelity gate is the full client suite against the package's CLI
# (BITSQL_BIN=dist/cli.js): the same tests the native image passes.
set -euo pipefail
cd "$(dirname "$0")/.."

push=0
for arg in "$@"; do
  case $arg in
    --push) push=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

version=$(sed -n 's/^version = "\(.*\)"/\1/p' moon.mod)
pkg=npm/bitsql
grep -q "\"version\": \"$version\"" "$pkg/package.json" ||
  { echo "$pkg/package.json version differs from moon.mod $version" >&2; exit 1; }

(cd "$pkg" && npm ci --silent --no-audit --no-fund && npm run --silent build)
cp LICENSE.md THIRD_PARTY_NOTICES.md "$pkg/"
rm -rf "$pkg/licenses" && cp -r licenses "$pkg/licenses"
[[ $(node "$pkg/dist/cli.js" --version) == "bitsql $version" ]] || { echo "CLI version mismatch" >&2; exit 1; }
echo "== bitsql $version: package tests"
(cd "$pkg" && npm test --silent 2>&1 | grep -E '^ℹ (pass|fail) ')

echo "== harness against the wasm build"
log=$(cd harness && BITSQL_BIN="$PWD/../$pkg/dist/cli.js" npm test --silent 2>&1) ||
  { echo "$log" | tail -40; echo "== harness FAILED" >&2; exit 1; }
grep -q '^SKIP' <<<"$log" && { echo "$log" | head; echo "== harness skipped" >&2; exit 1; }
grep -E '^ℹ (pass|fail|skipped) ' <<<"$log" | tr '\n' ' '; echo

out=$PWD/_build/npm
rm -rf "$out" && mkdir -p "$out/smoke"
(cd "$pkg" && npm pack -q --pack-destination "$out" >/dev/null)
echo "== packed: $(tar tzf "$out/bitsql-$version.tgz" | sed 's#^package/##' | tr '\n' ' ')"
# Installed from the tarball alone (no dependencies), imported both ways.
echo '{"private":true}' >"$out/smoke/package.json"
(cd "$out/smoke" && npm install -q --offline --no-audit --no-fund "../bitsql-$version.tgz" >/dev/null &&
  node -e "require('bitsql').start().then(s => s.stop()).then(() => console.log('== smoke (CommonJS): ok'))" &&
  node --input-type=module -e "import { start, version } from 'bitsql'; const s = await start(); await s.stop(); console.log('== smoke (ESM): ok', version)" &&
  npx --no-install bitsql --version)

if ((push)); then
  npm publish --access public "$out/bitsql-$version.tgz"
  npm view "bitsql@$version" version dist.unpackedSize
fi
