#!/usr/bin/env bash
# npm packages for this host's architecture: `bitsql` (launcher + typings) and
# `bitsql-<os>-<cpu>` (the release binary). Native host only, like the image.
#   scripts/npm-publish.sh          stage, pack and test in _build/npm
#   scripts/npm-publish.sh --push   also publish both (npm login first)
# The binary is the release build from scripts/docker-publish.sh
# (_build/xarch/<arch>/bitsql); BITSQL_BIN=path overrides it. The launcher's
# optionalDependencies list this host's package plus platform packages
# already published under the SAME version (each host publishes its own).
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
case $(uname -m) in
  x86_64) arch=amd64 cpu=x64 ;;
  aarch64|arm64) arch=arm64 cpu=arm64 ;;
  *) echo "Unsupported native architecture: $(uname -m)" >&2; exit 1 ;;
esac
os=linux
[[ $(uname -s) == Linux ]] || { echo "Only Linux hosts are packaged" >&2; exit 1; }
bin=${BITSQL_BIN:-_build/xarch/$arch/bitsql}
[[ -x $bin ]] || { echo "No release binary at $bin: run scripts/docker-publish.sh first" >&2; exit 1; }
[[ $("$bin" --version) == "bitsql $version" ]] ||
  { echo "$bin is $("$bin" --version), not bitsql $version" >&2; exit 1; }

out=$PWD/_build/npm
platform=bitsql-$os-$cpu
rm -rf "$out" && mkdir -p "$out/bitsql" "$out/$platform/bin"
licenses() {
  cp LICENSE.md THIRD_PARTY_NOTICES.md "$1/"
  cp -r licenses "$1/licenses"
  cp docs/reference/vendor/re2/LICENSE "$1/re2-LICENSE"
}

# Platform package: the binary and its notices (as in the image).
cp "$bin" "$out/$platform/bin/bitsql"
licenses "$out/$platform"
node -e '
const [version, os, cpu, platform] = process.argv.slice(1)
const pkg = {
  name: platform, version,
  description: `bitsql server binary for ${os}-${cpu} (glibc 2.34+); install bitsql instead`,
  homepage: "https://github.com/mirek/bitsql#readme",
  repository: { type: "git", url: "git+https://github.com/mirek/bitsql.git" },
  license: "CC0-1.0", author: "Mirek Rusin",
  os: [os], cpu: [cpu], libc: ["glibc"],
  files: ["bin/bitsql", "LICENSE.md", "THIRD_PARTY_NOTICES.md", "licenses", "re2-LICENSE"],
}
process.stdout.write(JSON.stringify(pkg, null, 2) + "\n")
' "$version" "$os" "$cpu" "$platform" >"$out/$platform/package.json"
printf '# %s\n\nThe native [bitsql](https://www.npmjs.com/package/bitsql) server for %s-%s.\nInstall `bitsql`, which depends on it.\n' \
  "$platform" "$os" "$cpu" >"$out/$platform/README.md"

# Launcher package.
platforms=("$platform")
for other in bitsql-linux-x64 bitsql-linux-arm64; do
  [[ $other == "$platform" ]] && continue
  if npm view "$other@$version" version >/dev/null 2>&1; then platforms+=("$other"); fi
done
cp npm/bitsql/{index.js,index.mjs,index.d.ts,README.md} "$out/bitsql/"
mkdir -p "$out/bitsql/bin" && cp npm/bitsql/bin/bitsql.js "$out/bitsql/bin/"
licenses "$out/bitsql"
node -e '
const fs = require("fs")
const [version, ...platforms] = process.argv.slice(1)
const pkg = JSON.parse(fs.readFileSync("npm/bitsql/package.json", "utf8"))
pkg.version = version
pkg.files.push("LICENSE.md", "THIRD_PARTY_NOTICES.md", "licenses", "re2-LICENSE")
pkg.optionalDependencies = Object.fromEntries(platforms.map(p => [p, version]))
process.stdout.write(JSON.stringify(pkg, null, 2) + "\n")
' "$version" "${platforms[@]}" >"$out/bitsql/package.json"
echo "== bitsql $version, platforms: ${platforms[*]}"

(cd "$out" && npm pack -q ./bitsql "./$platform" >/dev/null)

# Smoke: install the tarballs (offline), run tedious/mssql against them,
# type-check a consumer.
smoke=$out/smoke
mkdir -p "$smoke"
echo '{"name":"bitsql-smoke","private":true,"type":"module"}' >"$smoke/package.json"
(cd "$smoke" && npm install -q --offline --no-audit --no-fund \
  "../bitsql-$version.tgz" "../$platform-$version.tgz" >/dev/null)
cp npm/test/smoke.test.mjs npm/test/types.ts "$smoke/"
(cd "$smoke" && env -u BITSQL_BIN BITSQL_HARNESS="$PWD/../../../harness" node --test smoke.test.mjs) ||
  { echo "== npm smoke FAILED" >&2; exit 1; }
tsc=website/node_modules/.bin/tsc
if [[ -x $tsc ]]; then
  ln -s "$PWD/website/node_modules/@types" "$smoke/node_modules/@types"
  (cd "$smoke" && "$OLDPWD/$tsc" --noEmit --strict --target es2022 --module nodenext --types node types.ts)
  echo "== typings: ok"
else
  echo "== typings: skipped (no $tsc; run pnpm install in website/)" >&2
  ((push)) && exit 1
fi

if ((push)); then
  (cd "$out" && npm publish --access public "./$platform-$version.tgz" && npm publish --access public "./bitsql-$version.tgz")
  npm view "bitsql@$version" version optionalDependencies
fi
