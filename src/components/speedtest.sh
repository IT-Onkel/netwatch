#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: speedtest.sh run LOG_DIR TIMEOUT_SEC"; }
die() { echo "ERROR: $*" >&2; exit 1; }
ts() { date -Is; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

write_header_if_missing() {
  local csv="$1"
  if [[ ! -f "$csv" ]]; then
    printf "time_iso,provider,ping_ms,down_mbps,up_mbps,packet_loss,result_url,status,error,raw_path\n" > "$csv"
  fi
}

# Extract the LAST JSON object line that looks like {"type":"result",...}
extract_result_json() {
  # shellcheck disable=SC2002
  cat "$1" \
    | grep -E '^\{.*\}$' \
    | jq -c 'select(.type=="result")' 2>/dev/null \
    | tail -n 1
}

# Extract LAST log error line (if any)
extract_error_msg() {
  cat "$1" \
    | grep -E '^\{.*\}$' \
    | jq -r 'select(.type=="log" and .level=="error") | .message' 2>/dev/null \
    | tail -n 1
}

main() {
  [[ "${1:-}" == "run" ]] || { usage; exit 2; }
  local log_dir="${2:-}"
  local timeout_sec="${3:-60}"

  [[ -n "${log_dir}" ]] || die "LOG_DIR empty"
  [[ "${timeout_sec}" =~ ^[0-9]+$ ]] || die "TIMEOUT_SEC must be integer"

  need_cmd speedtest
  need_cmd jq
  need_cmd timeout

  mkdir -p "${log_dir}/speedtest"
  local csv="${log_dir}/speedtest.csv"
  write_header_if_missing "${csv}"

  local stamp raw time_iso
  stamp="$(date +%Y%m%dT%H%M%S)"
  raw="${log_dir}/speedtest/speedtest_${stamp}.txt"
  time_iso="$(ts)"

  # IMPORTANT:
  # - use --format=json to reduce noise
  # - keep stdout+stderr in raw
  # - timeout with -k so it doesn't hang forever
  set +e
  timeout -k 3 "${timeout_sec}" speedtest --accept-license --accept-gdpr --format=json >"${raw}" 2>&1
  rc=$?
  set -e

  provider="ookla"
  result_json="$(extract_result_json "${raw}" || true)"
  err_msg="$(extract_error_msg "${raw}" || true)"

  if [[ -n "${result_json}" ]]; then
    ping_ms="$(jq -r '.ping.latency // empty' <<<"${result_json}" 2>/dev/null || true)"
    down_mbps="$(jq -r '(.download.bandwidth // empty) * 8 / 1000000' <<<"${result_json}" 2>/dev/null || true)"
    up_mbps="$(jq -r '(.upload.bandwidth // empty) * 8 / 1000000' <<<"${result_json}" 2>/dev/null || true)"
    packet_loss="$(jq -r '.packetLoss // empty' <<<"${result_json}" 2>/dev/null || true)"
    result_url="$(jq -r '.result.url // empty' <<<"${result_json}" 2>/dev/null || true)"

    # status:
    # if we got a result object, treat as ok, even if there was also a log error line.
    status="ok"
    # If speedtest returned nonzero, keep that info in error column
    if [[ $rc -ne 0 ]]; then
      extra="exit=${rc}"
      if [[ -n "${err_msg}" ]]; then
        err_msg="${err_msg}; ${extra}"
      else
        err_msg="${extra}"
      fi
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,"%s",%s\n' \
      "${time_iso}" "${provider}" "${ping_ms}" "${down_mbps}" "${up_mbps}" "${packet_loss}" "${result_url}" "${status}" "${err_msg:-}" "${raw}" \
      >> "${csv}"
  else
    # No JSON result. Record fail with useful tail snippet.
    tailmsg="$(tail -n 8 "${raw}" | tr '\n' ' ' | sed 's/"/""/g')"
    final_err="${err_msg:-}"
    if [[ -z "${final_err}" ]]; then
      final_err="${tailmsg}"
    else
      final_err="${final_err}; ${tailmsg}"
    fi
    printf '%s,%s,,,,,,fail,"%s",%s\n' \
      "${time_iso}" "${provider}" "${final_err}" "${raw}" \
      >> "${csv}"
  fi
}

main "$@"
