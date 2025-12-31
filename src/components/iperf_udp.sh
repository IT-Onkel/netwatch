#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: iperf_udp.sh run LOG_DIR host:port BW TIME_SEC TIMEOUT_SEC"
  echo "   or: iperf_udp.sh run LOG_DIR host port BW TIME_SEC TIMEOUT_SEC"
}

die() { echo "ERROR: $*" >&2; exit 1; }
ts() { date -Is; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

# Parse args:
# A) run LOG_DIR host:port BW TIME TIMEOUT
# B) run LOG_DIR host port BW TIME TIMEOUT
parse_args() {
  local mode="${1:-}"
  [[ "$mode" == "run" ]] || { usage; exit 2; }

  LOG_DIR="${2:-}"
  [[ -n "${LOG_DIR}" ]] || die "LOG_DIR empty"

  local a3="${3:-}"
  local a4="${4:-}"
  local a5="${5:-}"
  local a6="${6:-}"
  local a7="${7:-}"

  if [[ "${a3}" == *:* ]]; then
    HOST="${a3%%:*}"
    PORT="${a3##*:}"
    BW="${a4:-}"
    TIME_SEC="${a5:-}"
    TIMEOUT_SEC="${a6:-}"
  else
    HOST="${a3:-}"
    PORT="${a4:-}"
    BW="${a5:-}"
    TIME_SEC="${a6:-}"
    TIMEOUT_SEC="${a7:-}"
  fi

  [[ -n "${HOST}" ]] || die "HOST empty"
  [[ -n "${PORT}" ]] || die "PORT empty"
  [[ "${PORT}" =~ ^[0-9]+$ ]] || die "Bad port: ${PORT}"
  [[ -n "${BW}" ]] || die "BW empty"
  [[ -n "${TIME_SEC}" ]] || die "TIME_SEC empty"
  [[ "${TIME_SEC}" =~ ^[0-9]+$ ]] || die "TIME_SEC must be integer seconds"
  [[ -n "${TIMEOUT_SEC}" ]] || die "TIMEOUT_SEC empty"
  [[ "${TIMEOUT_SEC}" =~ ^[0-9]+$ ]] || die "TIMEOUT_SEC must be integer seconds"
}

write_header_if_missing() {
  local csv="${LOG_DIR}/iperf_udp.csv"
  if [[ ! -f "$csv" ]]; then
    printf "time_iso,server,port,bw_mbps,jitter_ms,loss_pct,datagrams,status,raw_path,error\n" > "$csv"
  fi
}

main() {
  need_cmd iperf3
  need_cmd jq
  need_cmd timeout

  parse_args "$@"

  mkdir -p "${LOG_DIR}/iperf"
  write_header_if_missing

  local stamp raw csv time_iso
  stamp="$(date +%Y%m%dT%H%M%S)"
  raw="${LOG_DIR}/iperf/iperf_udp_${stamp}.json"
  csv="${LOG_DIR}/iperf_udp.csv"
  time_iso="$(ts)"

  # Run iperf3 UDP JSON. Important: `timeout -k` so it doesn't hang forever.
  # We keep stderr together to raw file as well (useful evidence).
  set +e
  timeout -k 3 "${TIMEOUT_SEC}" \
    iperf3 -c "${HOST}" -p "${PORT}" -u -b "${BW}" -t "${TIME_SEC}" -J \
    >"${raw}" 2>&1
  rc=$?
  set -e

  # If iperf3 produced JSON, parse it. Otherwise record fail with error snippet.
  if jq -e . >/dev/null 2>&1 < "${raw}"; then
    # UDP summary is typically in .end.sum (receiver) with jitter_ms + lost_percent + packets etc.
    # bandwidth is bits_per_second.
    bw_mbps="$(jq -r '(.end.sum.bits_per_second // empty) / 1000000' "${raw}" 2>/dev/null || true)"
    jitter_ms="$(jq -r '(.end.sum.jitter_ms // empty)' "${raw}" 2>/dev/null || true)"
    loss_pct="$(jq -r '(.end.sum.lost_percent // empty)' "${raw}" 2>/dev/null || true)"
    datagrams="$(jq -r '(.end.sum.packets // empty)' "${raw}" 2>/dev/null || true)"

    # Normalize empties
    [[ -n "${bw_mbps}" ]] || bw_mbps=""
    [[ -n "${jitter_ms}" ]] || jitter_ms=""
    [[ -n "${loss_pct}" ]] || loss_pct=""
    [[ -n "${datagrams}" ]] || datagrams=""

    if [[ $rc -eq 0 ]]; then
      status="ok"
      err=""
    else
      # Nonzero but still JSON: keep status=fail and store error code
      status="fail"
      err="exit=${rc}"
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
      "${time_iso}" "${HOST}" "${PORT}" "${bw_mbps}" "${jitter_ms}" "${loss_pct}" "${datagrams}" "${status}" "${raw}" "${err}" \
      >> "${csv}"
  else
    # Not valid JSON; store tail as error evidence.
    tailmsg="$(tail -n 5 "${raw}" | tr '\n' ' ' | sed 's/"/""/g')"
    printf '%s,%s,%s,,,,,fail,%s,"%s"\n' \
      "${time_iso}" "${HOST}" "${PORT}" "${raw}" "${tailmsg}" \
      >> "${csv}"
  fi
}

main "$@"
