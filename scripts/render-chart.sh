#!/usr/bin/env bash
set -euo pipefail

# OpenTelemetry Demo Helm chart → flat manifests for Kustomize
# Each K8s resource is written to its own file: <kind>-<name>.yaml
CHART_NAME="open-telemetry/opentelemetry-demo"
CHART_VERSION="0.40.7"
RELEASE_NAME="otel-demo"
NAMESPACE="otel-demo"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/otel-demo/base/manifests"
TMPFILE="$(mktemp)"

echo "==> Rendering ${CHART_NAME} v${CHART_VERSION} ..."

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# Render to single file
helm template "${RELEASE_NAME}" "${CHART_NAME}" \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" > "${TMPFILE}"

# Split into per-resource files using awk
cd "${OUTPUT_DIR}"
awk '
BEGIN { docnum=0; content="" }
/^---/ {
  if (content != "") {
    write_file()
  }
  content = ""
  kind = ""
  name = ""
  docnum++
  next
}
{
  content = content $0 "\n"
  if ($0 ~ /^kind:/) {
    gsub(/^kind: */, "", $0)
    kind = tolower($0)
  }
  if ($0 ~ /^  name:/ && name == "") {
    gsub(/^  name: */, "", $0)
    gsub(/"/, "", $0)
    name = tolower($0)
  }
}
END {
  if (content != "") write_file()
}
function write_file() {
  if (kind == "" || name == "") return
  # sanitize
  gsub(/[^a-z0-9-]/, "-", name)
  base = kind "-" name
  filename = base ".yaml"
  # handle duplicates
  if (filename in seen) {
    seen[filename]++
    filename = base "-" seen[filename] ".yaml"
  } else {
    seen[filename] = 0
  }
  printf "%s", content > filename
  close(filename)
  print "  " filename
}
' "${TMPFILE}"

rm -f "${TMPFILE}"

echo ""
echo "==> Rendered to ${OUTPUT_DIR}"
echo "==> Chart version: ${CHART_VERSION}"
echo "==> Total files: $(ls -1 "${OUTPUT_DIR}" | wc -l | tr -d ' ')"
