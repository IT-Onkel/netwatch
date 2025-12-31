#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/../lib.sh"

usage() { die "usage: speedtest.sh run LOG_DIR TIMEOUT_SEC"; }

cmd="${1:-}"; shift || true
[[ "$cmd" == "run" ]] || usage

LOG_DIR="${1:-}"; TIMEOUT="${2:-60}"
[[ -n "$LOG_DIR" ]] || usage

mkdirp "${LOG_DIR}/speedtest"
ts="$(ts_iso)"
tsf="$(date +%Y%m%dT%H%M%S)"
raw="${LOG_DIR}/speedtest/speedtest_${tsf}.txt"

provider=""
ping_ms=""
down_mbps=""
up_mbps=""
ploss=""
url=""
status="fail"
err=""

append() {
  csv_append "${LOG_DIR}/speedtest.csv" "${ts},${provider},${ping_ms},${down_mbps},${up_mbps},${ploss},${url},${status},\"$(printf "%s" "$err" | json_escape)\""
}

try_ookla() {
  provider="ookla"
  # Make crashes non-fatal:
  set +e
  timeout "$TIMEOUT" speedtest --accept-license --accept-gdpr --format=json >"$raw" 2>&1
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    # Could be crash; keep raw and record error
    err="ookla exit=$rc (see raw: $raw)"
    return 1
  fi

  if jq -e . >/dev/null 2>&1 <"$raw"; then
    ping_ms="$(jq -r '.ping.latency // empty' <"$raw")"
    down_mbps="$(jq -r '.download.bandwidth // empty' <"$raw" | awk '{print ($1*8/1000000)}')"
    up_mbps="$(jq -r '.upload.bandwidth // empty' <"$raw" | awk '{print ($1*8/1000000)}')"
    ploss="$(jq -r '.packetLoss // empty' <"$raw")"
    url="$(jq -r '.result.url // empty' <"$raw")"
    status="ok"
    err=""
    return 0
  fi

  err="ookla output not json (see raw: $raw)"
  return 1
}

try_speedtest_cli() {
  provider="speedtest-cli"
  set +e
  timeout "$TIMEOUT" speedtest-cli --json >"$raw" 2>&1
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    err="speedtest-cli exit=$rc (see raw: $raw)"
    return 1
  fi

  if jq -e . >/dev/null 2>&1 <"$raw"; then
    ping_ms="$(jq -r '.ping // empty' <"$raw")"
    down_mbps="$(jq -r '.download // empty' <"$raw" | awk '{print ($1/1000000)}')"
    up_mbps="$(jq -r '.upload // empty' <"$raw" | awk '{print ($1/1000000)}')"
    url="$(jq -r '.share // empty' <"$raw")"
    status="ok"
    err=""
    return 0
  fi

  err="speedtest-cli output not json (see raw: $raw)"
  return 1
}

# Prefer Ookla if present, but FALLBACK if it crashes
if have_cmd speedtest; then
  try_ookla || {
    # Detect your specific crash string explicitly (helps evidence)
    if grep -q "basic_string::_M_construct null not valid" "$raw" 2>/dev/null; then
      err="ookla crashed (basic_string null). Falling back."
    fi
    if have_cmd speedtest-cli; then
      try_speedtest_cli || true
    fi
  }
elif have_cmd speedtest-cli; then
  try_speedtest_cli || true
else
  provider="none"
  err="no speedtest binary found"
fi

append
exit 0
