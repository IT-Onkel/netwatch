#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${BASE_DIR}/lib.sh"

CONFIG_FILE="/etc/netwatch/netwatch.conf"

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Config fehlt: ${CONFIG_FILE} (install.sh legt ein Beispiel an)"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${LOG_DIR:?}"
  : "${EXPORT_DIR:?}"
  : "${SUMMARY_INTERVAL_SEC:?}"
  : "${PING_BURST_INTERVAL_SEC:?}"
  : "${MTR_INTERVAL_SEC:?}"
  : "${IPERF_UDP_INTERVAL_SEC:?}"
  : "${SPEEDTEST_INTERVAL_SEC:?}"
}

init_storage() {
  mkdirp "$LOG_DIR"
  mkdirp "$EXPORT_DIR"
  if [[ ! -f "${LOG_DIR}/ping_5min.csv" ]]; then
    printf "time_iso,window_s,target,sent,received,loss_pct,rtt_min_ms,rtt_avg_ms,rtt_max_ms,rtt_mdev_ms\n" > "${LOG_DIR}/ping_5min.csv"
  fi
  if [[ ! -f "${LOG_DIR}/dns_5min.csv" ]]; then
    printf "time_iso,window_s,resolver,domain,rr,status,qtime_ms,token\n" > "${LOG_DIR}/dns_5min.csv"
  fi
}

duration_seconds() {
  if [[ -n "${DURATION_SEC:-}" ]]; then
    echo "$DURATION_SEC"
  else
    echo $(( (${DURATION_HOURS:-24}) * 3600 ))
  fi
}

main() {
  load_config
  init_storage

  local run_id start_ts end_ts stop_requested
  run_id="$(date +%s)"
  start_ts="$(ts_epoch)"
  end_ts=$(( start_ts + $(duration_seconds) ))
  stop_requested=0
  trap 'stop_requested=1' TERM INT

  log_jsonl "${LOG_DIR}/events.jsonl" "{\"type\":\"start\",\"run_id\":${run_id},\"end_ts\":${end_ts}}"

  local next_ping next_summary next_mtr next_iperf next_speed
  local now
  now="$(ts_epoch)"
  next_ping="$now"
  next_summary="$now"
  next_mtr="$now"
  next_iperf="$now"
  next_speed="$now"

  while [[ "$stop_requested" -eq 0 ]]; do
    now="$(ts_epoch)"
    if (( now >= end_ts )); then
      break
    fi

    if (( now >= next_ping )); then
      for t in "${PING_TARGETS[@]}"; do
        "${BASE_DIR}/components/ping_quality.sh" burst "$LOG_DIR" "$t" "${PING_BURST_COUNT}" "${PING_BURST_I}"
      done
      next_ping=$(( now + PING_BURST_INTERVAL_SEC ))
    fi

    if (( now >= next_summary )); then
      for t in "${PING_TARGETS[@]}"; do
        "${BASE_DIR}/components/ping_quality.sh" summary "$LOG_DIR" "$t" "$SUMMARY_INTERVAL_SEC"
      done

      # DNS local + upstream
      "${BASE_DIR}/components/dns_quality.sh" "$LOG_DIR" "$SUMMARY_INTERVAL_SEC" "$LOCAL_DNS" "${DNS_TEST_DOMAINS[@]}"
      for r in "${UPSTREAM_DNS[@]}"; do
        "${BASE_DIR}/components/dns_quality.sh" "$LOG_DIR" "$SUMMARY_INTERVAL_SEC" "$r" "${DNS_TEST_DOMAINS[@]}"
      done

      next_summary=$(( now + SUMMARY_INTERVAL_SEC ))
    fi

    if (( now >= next_mtr )); then
      for t in "${PING_TARGETS[@]}"; do
        "${BASE_DIR}/components/mtr_snapshot.sh" "$LOG_DIR" "$t"
      done
      next_mtr=$(( now + MTR_INTERVAL_SEC ))
    fi

    if (( now >= next_iperf )); then
      "${BASE_DIR}/components/iperf_udp.sh" "$LOG_DIR" "${IPERF3_SERVER}" "${IPERF3_PORT}" "${IPERF3_UDP_BW}" "${IPERF3_UDP_TIME}" || true
      next_iperf=$(( now + IPERF_UDP_INTERVAL_SEC ))
    fi

    if (( now >= next_speed )); then
      "${BASE_DIR}/components/speedtest.sh" "$LOG_DIR" "${SPEEDTEST_TIMEOUT_SEC}"
      next_speed=$(( now + SPEEDTEST_INTERVAL_SEC ))
    fi

    sleep 1
  done

  # Generate report + evidence bundle
  local out_dir bundle
  out_dir="${EXPORT_DIR}/run_${run_id}"
  mkdirp "$out_dir"
  "${BASE_DIR}/report/report.sh" "$LOG_DIR" "$out_dir"

  bundle="${EXPORT_DIR}/netwatch_evidence_${run_id}.tar.gz"
  tar -czf "$bundle" -C "$out_dir" . >/dev/null 2>&1 || true

  log_jsonl "${LOG_DIR}/events.jsonl" "{\"type\":\"stop\",\"run_id\":${run_id},\"bundle\":\"${bundle}\"}"

  exit 0
}

main "$@"
