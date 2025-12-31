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

run_ookla() {
  provider="ookla"
  # Ookla CLI supports --format=json in newer versions; fallback plain.
  if speedtest --help 2>/dev/null | grep -q -- '--format'; then
    if timeout "$TIMEOUT" speedtest --accept-license --accept-gdpr --format=json >"$raw" 2>&1; then
      :
    fi
    if jq -e . >/dev/null 2>&1 <"$raw"; then
      ping_ms="$(jq -r '.ping.latency // empty' <"$raw")"
      down_mbps="$(jq -r '.download.bandwidth // empty' <"$raw" | awk '{print ($1*8/1000000)}')" # bytes/s -> Mbps
      up_mbps="$(jq -r '.upload.bandwidth // empty' <"$raw" | awk '{print ($1*8/1000000)}')"
      ploss="$(jq -r '.packetLoss // empty' <"$raw")"
      url="$(jq -r '.result.url // empty' <"$raw")"
      status="ok"
      return 0
    fi
  fi

  # plain text mode
  if timeout "$TIMEOUT" speedtest --accept-license --accept-gdpr >"$raw" 2>&1; then
    :
  fi
  # try parsing plain
  ping_ms="$(awk -F': ' '/Latency/{print $2}' "$raw" | awk '{print $1}' | head -n1 || true)"
  down_mbps="$(awk -F': ' '/Download/{print $2}' "$raw" | awk '{print $1}' | head -n1 || true)"
  up_mbps="$(awk -F': ' '/Upload/{print $2}' "$raw" | awk '{print $1}' | head -n1 || true)"
  url="$(awk -F': ' '/Result URL/{print $2}' "$raw" | head -n1 || true)"

  if [[ -n "$down_mbps" || -n "$up_mbps" ]]; then
    status="ok"
    return 0
  fi

  err="ookla parse failed or blocked (see raw)"
  return 1
}

run_speedtest_cli() {
  provider="speedtest-cli"
  if timeout "$TIMEOUT" speedtest-cli --json >"$raw" 2>&1; then
    :
  fi
  if jq -e . >/dev/null 2>&1 <"$raw"; then
    ping_ms="$(jq -r '.ping // empty' <"$raw")"
    down_mbps="$(jq -r '.download // empty' <"$raw" | awk '{print ($1/1000000)}')"
    up_mbps="$(jq -r '.upload // empty' <"$raw" | awk '{print ($1/1000000)}')"
    url="$(jq -r '.share // empty' <"$raw")"
    status="ok"
    return 0
  fi
  err="speedtest-cli json parse failed"
  return 1
}

if have_cmd speedtest; then
  run_ookla || true
elif have_cmd speedtest-cli; then
  run_speedtest_cli || true
else
  provider="none"
  err="no speedtest binary found"
fi

# If still fail, try alternate
if [[ "$status" != "ok" ]]; then
  if [[ "$provider" == "ookla" && -z "${down_mbps}" && have_cmd speedtest-cli ]]; then
    run_speedtest_cli || true
  elif [[ "$provider" == "speedtest-cli" && -z "${down_mbps}" && have_cmd speedtest ]]; then
    run_ookla || true
  fi
fi

if [[ "$status" != "ok" && -z "$err" ]]; then
  err="no numeric results (see raw)"
fi

csv_append "${LOG_DIR}/speedtest.csv" "${ts},${provider},${ping_ms},${down_mbps},${up_mbps},${ploss},${url},${status},\"$(printf "%s" "$err" | json_escape)\""
