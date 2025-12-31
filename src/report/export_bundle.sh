#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${BASE_DIR}/../lib.sh"

LOG_DIR="${1:-/var/log/netwatch}"
EXPORT_DIR="${2:-/var/log/netwatch/export}"
mkdirp "$EXPORT_DIR"

tsf="$(date +%Y%m%dT%H%M%S)"
bundle="${EXPORT_DIR}/netwatch_evidence_${tsf}.tar.gz"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# copy logs and reports
mkdir -p "$tmp/netwatch"
cp -a "$LOG_DIR"/*.csv "$tmp/netwatch/" 2>/dev/null || true
cp -a "$LOG_DIR"/events.jsonl "$tmp/netwatch/" 2>/dev/null || true
cp -a "$LOG_DIR"/ping_bursts.log "$tmp/netwatch/" 2>/dev/null || true
cp -a "$LOG_DIR"/mtr "$tmp/netwatch/" 2>/dev/null || true
cp -a "$LOG_DIR"/iperf "$tmp/netwatch/" 2>/dev/null || true
cp -a "$LOG_DIR"/speedtest "$tmp/netwatch/" 2>/dev/null || true
cp -a "$EXPORT_DIR"/report_* "$tmp/netwatch/" 2>/dev/null || true

# include config (sanity)
if [[ -f /etc/netwatch/netwatch.conf ]]; then
  cp -a /etc/netwatch/netwatch.conf "$tmp/netwatch/" || true
fi

tar -czf "$bundle" -C "$tmp" netwatch
sha="${bundle}.sha256"
sha256sum "$bundle" >"$sha"

echo "OK: created bundle:"
echo "  $bundle"
echo "  $sha"
