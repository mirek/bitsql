#!/usr/bin/env bash
# Scan bitsql images for known vulnerabilities with trivy and grype (both free,
# run as containers; nothing to install). Reads the registry directly, so no
# image is pulled and foreign architectures are only read, never executed.
#   scripts/image-scan.sh                       mirek/bitsql:latest, every arch
#   scripts/image-scan.sh mirek/bitsql:0.1.30   another published tag
#   LOCAL=1 scripts/image-scan.sh bitsql:dev    a local image (docker daemon)
#   SEVERITY=MEDIUM ...                         lower the failure threshold
# Exit 1 when either scanner finds a vulnerability that has a fix at or above
# SEVERITY (default HIGH). The fix is a rebuild: the apko base
# (scripts/base/apko.yaml) resolves the newest Wolfi packages on every build,
# so scripts/docker-publish.sh --push ships them; no versions need editing.
set -euo pipefail
image=${1:-mirek/bitsql:latest}
severity=${SEVERITY:-HIGH}
case $severity in LOW|MEDIUM|HIGH|CRITICAL) ;; *) echo "SEVERITY must be LOW, MEDIUM, HIGH or CRITICAL" >&2; exit 2 ;; esac
mkdir -p "$HOME/.cache/trivy" "$HOME/.cache/grype"
sock=(-v /var/run/docker.sock:/var/run/docker.sock)
tmp=_build/image-scan
cd "$(dirname "$0")/.." && mkdir -p "$tmp" && trap 'rm -rf "$tmp"' EXIT

if [[ ${LOCAL:-0} == 1 ]]; then
  platforms=("")
else
  platforms=()
  while read -r p; do platforms+=("$p"); done < <(docker manifest inspect "$image" | node -e '
const index = JSON.parse(require("fs").readFileSync(0, "utf8"))
for (const m of index.manifests ?? [{ platform: { os: "linux", architecture: "amd64" } }])
  if (m.platform.architecture !== "unknown") console.log(m.platform.os + "/" + m.platform.architecture)')
fi

failed=0
for platform in "${platforms[@]}"; do
  label=${platform:-local}
  targs=(--scanners vuln) gargs=()
  if [[ -n $platform ]]; then
    targs+=(--image-src remote --platform "$platform")
    gargs+=(--platform "$platform")
    gsrc="registry:$image"
  else
    targs+=(--image-src docker)
    gsrc="docker:$image"
  fi
  docker run --rm --name "bitsql-trivy-$$" "${sock[@]}" -v "$HOME/.cache/trivy:/root/.cache/trivy" \
    aquasec/trivy:latest image -q "${targs[@]}" --format json "$image" >"$tmp/trivy.json"
  docker run --rm --name "bitsql-grype-$$" "${sock[@]}" -v "$HOME/.cache/grype:/cache" \
    -e GRYPE_DB_CACHE_DIR=/cache anchore/grype:latest -q "${gargs[@]}" -o json "$gsrc" >"$tmp/grype.json"
  if ! node -e '
const fs = require("fs")
const [label, sev, trivyFile, grypeFile] = process.argv.slice(1)
const rank = { NEGLIGIBLE: 0, UNKNOWN: 0, LOW: 1, MEDIUM: 2, HIGH: 3, CRITICAL: 4 }
const min = rank[sev]
const rows = []
for (const t of JSON.parse(fs.readFileSync(trivyFile, "utf8")).Results ?? [])
  for (const v of t.Vulnerabilities ?? [])
    rows.push({ tool: "trivy", id: v.VulnerabilityID, pkg: v.PkgName, ver: v.InstalledVersion,
      sev: v.Severity, fix: v.FixedVersion || "" })
for (const m of JSON.parse(fs.readFileSync(grypeFile, "utf8")).matches ?? [])
  rows.push({ tool: "grype", id: m.vulnerability.id, pkg: m.artifact.name, ver: m.artifact.version,
    sev: m.vulnerability.severity.toUpperCase(), fix: (m.vulnerability.fix?.versions ?? []).join(" ") })
const count = tool => rows.filter(r => r.tool === tool).length
const blocking = rows.filter(r => r.fix && (rank[r.sev] ?? 0) >= min)
console.log(`== ${label}: trivy ${count("trivy")}, grype ${count("grype")} known vulnerabilities; ` +
  `${blocking.length} fixable at ${sev} or above`)
for (const r of blocking) console.log(`   ${r.tool} ${r.sev} ${r.id} ${r.pkg} ${r.ver} -> ${r.fix}`)
process.exit(blocking.length ? 1 : 0)' "$label" "$severity" "$tmp/trivy.json" "$tmp/grype.json"; then
    failed=1
  fi
done
if ((failed)); then
  echo "== fixes are available: rebuild and republish (scripts/docker-publish.sh --push on each native host)" >&2
  exit 1
fi
