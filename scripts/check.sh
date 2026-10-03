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
echo "== moon test"
moon test --target native 2>&1 | tail -n 5
echo "== moon fmt / info drift"
moon fmt >/dev/null && moon info >/dev/null
if ! git diff --quiet -- src; then
  echo "moon fmt / moon info changed files; commit them:"; git diff --stat -- src; exit 1
fi
if [ -d harness/node_modules ] && [ "${SKIP_HARNESS:-0}" != 1 ]; then
  echo "== harness (emulator)"
  (cd harness && npm test --silent)
fi
echo "OK"
