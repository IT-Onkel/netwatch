#!/usr/bin/env bash
set -euo pipefail

# usage: iperf_udp.sh LOG_DIR SERVER [PORT] [BW] [TIME]
LOG_DIR="${1:-}"
SERVER="${2:-}"
PORT="${3:-5201}"
BW="${4:-5M}"
TIME_S="${5:-30}"

[[ -n "${LOG_DIR}" ]] || { echo "ERROR: usage: iperf_udp.sh LOG_DIR SERVER [PORT] [BW] [TIME]" >&2; exit 2; }

# If no server configured, skip silently (optional component)
if [[ -z "${SERVER}" ]]; then
  exit 0
fi

ts="$(date -Is)"
out="${LOG_DIR}/iperf_udp_${SERVER//[^a-zA-Z0-9._-]/_}.log"

# Run a short UDP test; do not fail hard
iperf3 -u -c "${SERVER}" -p "${PORT}" -b "${BW}" -t "${TIME_S}" --json 2>/dev/null \
  | awk -v ts="${ts}" '{print ts " " $0}' >> "${out}" || {
    echo "${ts} ERROR iperf3 failed server=${SERVER} port=${PORT} bw=${BW} t=${TIME_S}" >> "${out}"
    exit 0
  }
