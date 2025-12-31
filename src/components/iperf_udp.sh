#!/usr/bin/env bash
set -euo pipefail

# iperf_udp.sh
# Usage:
#   iperf_udp.sh run LOG_DIR "host:port" BW TIME_SEC TIMEOUT_SEC
# Writes:
#   LOG_DIR/iperf_udp.csv
#   LOG_DIR/iperf/raw/iperf_<time>_<host>_<port>.json  (or .txt for non-json)
#
# status values: ok | timeout | ctrl_fail | fail | parse_fail

die() { echo "ERROR: $*" >&2; exit 1; }

ts_iso() { date -Is; }

have() { command -v "$1" >/dev/null 2>&1; }

sanitize() {
  # replace non filename chars
  echo "$1" | tr -c 'a-zA-Z0-9._-:' '_' | tr ':' '_'
}

ensure_headers() {
  local log_dir="$1"
  mkdir -p "${log_dir}/iperf/raw"
  if [[ ! -f "${log_dir}/iperf_udp.csv" ]]; then
    printf "time_iso,server,port,target_mbps,rx_mbps,jitter_ms,loss_pct,status,error,raw_file\n" > "${log_dir}/iperf_udp.csv"
  fi
}

mpbs_from_bw() {
  # input like "5M" "10M" "100K" "1G" or plain bits/s
  local bw="$1"
  bw="${bw// /}"
  if [[ "$bw" =~ ^[0-9]+([.][0-9]+)?[Kk]$ ]]; then
    awk -v v="${bw%[Kk]}" 'BEGIN{printf "%.3f", (v*1000)/1000000}'
  elif [[ "$bw" =~ ^[0-9]+([.][0-9]+)?[Mm]$ ]]; then
    awk -v v="${bw%[Mm]}" 'BEGIN{printf "%.3f", v}'
  elif [[ "$bw" =~ ^[0-9]+([.][0-9]+)?[Gg]$ ]]; then
    awk -v v="${bw%[Gg]}" 'BEGIN{printf "%.3f", (v*1000)}'
  elif [[ "$bw" =~ ^[0-9]+$ ]]; then
    # assume bits/sec
    awk -v v="$bw" 'BEGIN{printf "%.3f", (v)/1000000}'
  else
    echo ""
  fi
}

preflight_ctrl() {
  local host="$1" port="$2"
  if have nc; then
    # short TCP check for iperf control channel
    nc -vz -w 2 "$host" "$port" >/dev/null 2>&1
  else
    # no nc: don't fail preflight
    return 0
  fi
}

run_one() {
  local log_dir="$1"
  local hp="$2"
  local bw="$3"
  local tsec="$4"
  local timeout_sec="$5"

  local host port
  host="${hp%:*}"
  port="${hp##*:}"
  [[ -n "$host" && -n "$port" && "$host" != "$port" ]] || die "Bad host:port: $hp"

  ensure_headers "$log_dir"

  local iso raw_base raw_file status err
  iso="$(ts_iso)"
  raw_base="$(sanitize "${iso}_${host}_${port}")"
  raw_file="${log_dir}/iperf/raw/iperf_${raw_base}.json"

  local target_mbps
  target_mbps="$(mpbs_from_bw "$bw")"

  status="fail"
  err=""

  # Preflight: control channel reachable?
  if ! preflight_ctrl "$host" "$port"; then
    status="ctrl_fail"
    err="control_port_unreachable"
    printf "%s,%s,%s,%s,,,%s,%s,%s,%s\n" \
      "$iso" "$host" "$port" "${target_mbps:-}" "" "" "" "$status" "$err" "$raw_file" >> "${log_dir}/iperf_udp.csv"
    echo "{\"time\":\"$iso\",\"server\":\"$host\",\"port\":$port,\"status\":\"$status\",\"error\":\"$err\"}" > "$raw_file"
    return 0
  fi

  # Run iperf3 UDP with JSON output + hard timeout
  # iperf3 JSON includes receiver metrics even for UDP (if server returns)
  if ! have iperf3; then
    status="fail"
    err="iperf3_not_found"
    printf "%s,%s,%s,%s,,,%s,%s,%s,%s\n" \
      "$iso" "$host" "$port" "${target_mbps:-}" "" "" "" "$status" "$err" "$raw_file" >> "${log_dir}/iperf_udp.csv"
    echo "{\"time\":\"$iso\",\"server\":\"$host\",\"port\":$port,\"status\":\"$status\",\"error\":\"$err\"}" > "$raw_file"
    return 0
  fi

  # Prefer JSON (requires jq for parsing)
  local cmd_rc=0
  local tmp_json
  tmp_json="$(mktemp)"

  # Use LC_ALL=C to avoid comma decimals in some locales
  export LC_ALL=C

  if have timeout; then
    timeout "${timeout_sec}s" iperf3 -c "$host" -p "$port" -u -b "$bw" -t "$tsec" --json >"$tmp_json" 2>&1 || cmd_rc=$?
  else
    iperf3 -c "$host" -p "$port" -u -b "$bw" -t "$tsec" --json >"$tmp_json" 2>&1 || cmd_rc=$?
  fi

  # classify timeout
  if [[ "$cmd_rc" -eq 124 || "$cmd_rc" -eq 137 ]]; then
    status="timeout"
    err="iperf_timeout_${timeout_sec}s"
    mv "$tmp_json" "$raw_file"
    printf "%s,%s,%s,%s,,,%s,%s,%s,%s\n" \
      "$iso" "$host" "$port" "${target_mbps:-}" "" "" "" "$status" "$err" "$raw_file" >> "${log_dir}/iperf_udp.csv"
    return 0
  fi

  # Save raw output regardless
  mv "$tmp_json" "$raw_file"

  # Parse JSON if possible
  if ! have jq; then
    status="parse_fail"
    err="jq_not_found"
    printf "%s,%s,%s,%s,,,%s,%s,%s,%s\n" \
      "$iso" "$host" "$port" "${target_mbps:-}" "" "" "" "$status" "$err" "$raw_file" >> "${log_dir}/iperf_udp.csv"
    return 0
  fi

  # iperf3 --json on failure may not be valid JSON (might be text)
  if ! jq -e . >/dev/null 2>&1 <"$raw_file"; then
    status="parse_fail"
    err="non_json_output_rc_${cmd_rc}"
    printf "%s,%s,%s,%s,,,%s,%s,%s,%s\n" \
      "$iso" "$host" "$port" "${target_mbps:-}" "" "" "" "$status" "$err" "$raw_file" >> "${log_dir}/iperf_udp.csv"
    return 0
  fi

  # Extract receiver metrics. Some servers may omit receiver section.
  local rx_bps jitter_ms loss_pct
  rx_bps="$(jq -r '(.end.sum_received.bits_per_second // .end.sum.bits_per_second // empty)' "$raw_file")"
  jitter_ms="$(jq -r '(.end.sum_received.jitter_ms // .end.sum.jitter_ms // empty)' "$raw_file")"
  loss_pct="$(jq -r '(.end.sum_received.lost_percent // .end.sum.lost_percent // empty)' "$raw_file")"

  if [[ -z "${rx_bps:-}" ]]; then
    status="fail"
    err="missing_receiver_stats_rc_${cmd_rc}"
    printf "%s,%s,%s,%s,,,%s,%s,%s,%s\n" \
      "$iso" "$host" "$port" "${target_mbps:-}" "" "" "" "$status" "$err" "$raw_file" >> "${log_dir}/iperf_udp.csv"
    return 0
  fi

  # Convert bps -> Mbps
  local rx_mbps
  rx_mbps="$(awk -v v="$rx_bps" 'BEGIN{printf "%.2f", v/1000000}')"

  # jitter/loss may be null
  jitter_ms="${jitter_ms:-}"
  loss_pct="${loss_pct:-}"

  status="ok"
  err=""

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$iso" "$host" "$port" "${target_mbps:-}" "$rx_mbps" "${jitter_ms:-}" "${loss_pct:-}" "$status" "$err" "$raw_file" >> "${log_dir}/iperf_udp.csv"
}

main() {
  [[ "${1:-}" == "run" ]] || die "usage: iperf_udp.sh run LOG_DIR host:port BW TIME_SEC TIMEOUT_SEC"
  local log_dir="${2:-}"; local hp="${3:-}"; local bw="${4:-}"; local tsec="${5:-}"; local timeout_sec="${6:-}"
  [[ -n "$log_dir" && -n "$hp" && -n "$bw" && -n "$tsec" && -n "$timeout_sec" ]] || die "usage: iperf_udp.sh run LOG_DIR host:port BW TIME_SEC TIMEOUT_SEC"
  run_one "$log_dir" "$hp" "$bw" "$tsec" "$timeout_sec"
}

main "$@"
