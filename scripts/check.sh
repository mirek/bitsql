#!/usr/bin/env bash
# Everything that must be green before pushing to main.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== moon check (native)"
moon check --target native --deny-warn 2>&1 | tail -n 20
echo "== core purity (all backends)"
for pkg in $(ls -d src/core/*/ 2>/dev/null); do
  name=${pkg#src/}; name=${name%/}
  moon check --target all "$pkg" >/dev/null 2>&1 \
    || { echo "core package $name does not check on all backends"; moon check --target all "$pkg"; exit 1; }
done
echo "== release version"
mod=$(sed -n 's/^version = "\(.*\)"/\1/p' moon.mod)
grep -q "bitsql_version : String = \"$mod\"" src/core/exec/version.mbt \
  || { echo "src/core/exec/version.mbt bitsql_version differs from moon.mod $mod"; exit 1; }
echo "== moon test"
# MOON_TEST_JOBS=2 keeps parallel test links within an 8 GB dev container VM.
moon test --target native ${MOON_TEST_JOBS:+-j "$MOON_TEST_JOBS"} 2>&1 | tail -n 5
echo "== moon fmt / info drift"
snapshot() { find src -type f \( -name '*.mbt' -o -name '*.mbti' -o -name 'moon.pkg' \) -print0 | sort -z | xargs -0 sha1sum; }
before=$(snapshot)
moon fmt >/dev/null && moon info >/dev/null
if [ "$before" != "$(snapshot)" ]; then
  echo "moon fmt / moon info rewrote files (now fixed in the tree); review and re-run"; exit 1
fi
echo "== scripts (.mbtx check / fmt)"
# Plain `moon check` / `moon fmt` skip standalone scripts; check takes one path.
mapfile -t scripts < <(git ls-files 'scripts/*.mbtx')
for s in "${scripts[@]}"; do
  moon check --deny-warn "$s" >/dev/null 2>&1 \
    || { echo "$s does not check"; moon check --deny-warn "$s"; exit 1; }
done
moon fmt --check "${scripts[@]}" >/dev/null 2>&1 \
  || { echo "unformatted script: run moon fmt scripts/<name>.mbtx"; exit 1; }
if [ "${SKIP_GENERATORS:-0}" != 1 ]; then
  echo "== generated files match their generators"
  # Generators also write harness corpus files, so compare the whole tree.
  tree() { { git diff; git ls-files --others --exclude-standard; } | sha1sum; }
  before=$(tree)
  for s in $(git ls-files 'scripts/gen-*.mbtx'); do
    moon run -q "$s" >/dev/null 2>&1 || { echo "$s failed"; moon run -q "$s"; exit 1; }
  done
  moon fmt >/dev/null
  if [ "$before" != "$(tree)" ]; then
    echo "generated files differ from scripts/gen-*.mbtx output (now regenerated in the tree)"; exit 1
  fi
fi
if [ -d harness/node_modules ] && [ "${SKIP_HARNESS:-0}" != 1 ]; then
  echo "== harness (emulator)"
  (cd harness && npm test --silent)
fi
if [ -d website/node_modules ]; then
  echo "== website (JS engine, TypeScript, capture tests, production build)"
  pnpm --dir website test
  pnpm --dir website build
fi
echo "OK"
