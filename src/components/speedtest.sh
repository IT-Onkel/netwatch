#!/usr/bin/env bash
set -euo pipefail
# Produces: speedtest.csv (timestamp, provider, ping_ms, down_mbps, up_mbps, packet_loss?, result_url?)
. "$(dirname "$0")/../lib.sh"

run_ookla() {
  local timeout="$1"
  # Ookla speedtest supports --format=json
  # Some builds support --accept-license/--accept-gdpr
  timeout "${timeout}" speedtest --accept-license --accept-gdpr --format=json 2>/dev/null || true
}

run_speedtest_cli() {
  local timeout="$1"
  # speedtest-cli supports --json
  timeout "${timeout}" speedtest-cli --json 2>/dev/null || true
}

main() {
  local log_dir="${1:-}"
  local timeout_s="${2:-60}"
  [[ -n "$log_dir" ]] || die "usage: speedtest.sh LOG_DIR [timeout_s]"

  local now_iso provider json ping down up url loss
  now_iso="$(ts_iso)"
  provider=""
  json=""

  if have_cmd speedtest; then
    provider="ookla"
    json="$(run_ookla "$timeout_s")"
    # parse typical fields
    ping="$(jq -r '.ping.latency // empty' <<<"$json" 2>/dev/null || true)"
    down="$(jq -r '(.download.bandwidth // 0) * 8 / 1000000' <<<"$json" 2>/dev/null || true)" # bytes/s -> Mbit/s
    up="$(jq -r '(.upload.bandwidth // 0) * 8 / 1000000' <<<"$json" 2>/dev/null || true)"
    url="$(jq -r '.result.url // empty' <<<"$json" 2>/dev/null || true)"
    loss="$(jq -r '.packetLoss // empty' <<<"$json" 2>/dev/null || true)"
  elif have_cmd speedtest-cli; then
    provider="speedtest-cli"
    json="$(run_speedtest_cli "$timeout_s")"
    ping="$(jq -r '.ping // empty' <<<"$json" 2>/dev/null || true)"
    down="$(jq -r '(.download // 0) / 1000000' <<<"$json" 2>/dev/null || true)" # bits/s -> Mbit/s
    up="$(jq -r '(.upload // 0) / 1000000' <<<"$json" 2>/dev/null || true)"
    url="$(jq -r '.share // empty' <<<"$json" 2>/dev/null || true)"
    loss=""
  else
    # not available -> write a row that indicates missing
    provider="none"
    ping=""; down=""; up=""; url=""; loss=""
  fi

  mkdirp "$log_dir"
  if [[ ! -f "${log_dir}/speedtest.csv" ]]; then
    printf "time_iso,provider,ping_ms,down_mbps,up_mbps,packet_loss,result_url\n" > "${log_dir}/speedtest.csv"
  fi

  printf "%s,%s,%s,%s,%s,%s,%s\n" \
    "$now_iso" "$provider" "${ping:-}" "${down:-}" "${up:-}" "${loss:-}" "${url:-}" \
    >> "${log_dir}/speedtest.csv"
}

main "$@"
