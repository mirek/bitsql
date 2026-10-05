#!/usr/bin/env bash
# CPU profile of the release emulator on benchmark shapes or ad-hoc SQL,
# without perf or ptrace (both are restricted on the shared host): a
# SIGPROF sampler is LD_PRELOADed into the server (scripts/profile/sampler.c).
#
#   scripts/profile.sh 'GROUP BY v'              # shapes matching a regexp
#   SQL='SELECT SUM(p + 1) FROM w' scripts/profile.sh
#   REPS=50 scripts/profile.sh 'UPDATE all' --callers drop_object
#   WORKLOAD=requests REPS=3 scripts/profile.sh   # per-request workload (compare.mjs)
#
# Extra arguments go to scripts/profile/report.py (--top N, --callers FUNC).
# Samples live in _build/profile/ and are replaced on each run.
set -euo pipefail
cd "$(dirname "$0")/.."
shape=${1:-.}; shift || true
out=_build/profile
mkdir -p "$out"
rm -f "$out"/prof.*
moon build --target native --release >/dev/null
exe=$PWD/_build/native/release/build/host/host.exe
cc -O2 -shared -fPIC -w -o "$out/sampler.so" scripts/profile/sampler.c
cat > "$out/host.sh" <<SH
#!/bin/sh
SAMPLER_OUT=$PWD/$out/prof LD_PRELOAD=$PWD/$out/sampler.so exec $exe "\$@"
SH
chmod +x "$out/host.sh"
(cd harness && SHAPE="$shape" BITSQL_BIN="$PWD/../$out/host.sh" node bench/profile.mjs)
data=$(ls "$out"/prof.* | grep -v '\.maps$' | head -n 1)
python3 scripts/profile/report.py "$data" "$exe" "$@"
