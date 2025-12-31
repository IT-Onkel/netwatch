#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/../lib.sh"

usage() { die "usage: iperf_udp.sh run LOG_DIR SERVER PORT BW TIME"; }

cmd="${1:-}"; shift || true
[[ "$cmd" == "run" ]] || usage

LOG_DIR="${1:-}"; SERVER="${2:-}"; PORT="${3:-5201}"; BW="${4:-5M}"; TIME="${5:-20}"
[[ -n "$LOG_DIR" ]] || usage

# optional: skip if server empty
if [[ -z "${SERVER}" ]]; then
  exit 0
fi

mkdirp "${LOG_DIR}/iperf"
ts="$(ts_iso)"
tsf="$(date +%Y%m%dT%H%M%S)"
raw="${LOG_DIR}/iperf/iperf_udp_${SERVER}_${tsf}.txt"

if ! have_cmd iperf3; then
  csv_append "${LOG_DIR}/iperf_udp.csv" "${ts},${SERVER},${PORT},,,,,fail,${raw}"
  echo "iperf3 not installed" >"$raw"
  exit 0
fi

# iperf3 UDP client; keep raw output
iperf3 -c "$SERVER" -p "$PORT" -u -b "$BW" -t "$TIME" -J >"$raw" 2>&1 || true

# Parse JSON if valid
if jq -e . >/dev/null 2>&1 <"$raw"; then
  # Convert BW to Mbps numeric if possible (BW param); but we use measured
  bw_mbps="$(jq -r '.end.sum.bits_per_second // empty' <"$raw" | awk '{print ($1/1000000)}')"
  jitter_ms="$(jq -r '.end.sum.jitter_ms // empty' <"$raw")"
  lost="$(jq -r '.end.sum.lost_packets // empty' <"$raw")"
  total="$(jq -r '.end.sum.packets // empty' <"$raw")"

  loss_pct=""
  if [[ -n "${lost}" && -n "${total}" && "$total" != "0" ]]; then
    loss_pct="$(awk -v l="$lost" -v t="$total" 'BEGIN{printf "%.2f", (l/t)*100}')"
  fi

  status="ok"
  if [[ -z "${bw_mbps}" ]]; then status="fail"; fi

  csv_append "${LOG_DIR}/iperf_udp.csv" "${ts},${SERVER},${PORT},${bw_mbps:-},${jitter_ms:-},${loss_pct:-},${total:-},${status},${raw}"
else
  csv_append "${LOG_DIR}/iperf_udp.csv" "${ts},${SERVER},${PORT},,,,,fail,${raw}"
fi
