#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${BASE_DIR}/lib.sh"

APP="netwatch"
CONFIG_FILE="/etc/${APP}/${APP}.conf"
EXAMPLE_FILE="${BASE_DIR}/config.example.conf"

load_config() {
  # If config is missing, attempt to create it from example (prevents restart-loop)
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    if [[ -f "${EXAMPLE_FILE}" && -s "${EXAMPLE_FILE}" ]]; then
      mkdir -p "/etc/${APP}"
      cp "${EXAMPLE_FILE}" "${CONFIG_FILE}"
      chmod 0644 "${CONFIG_FILE}" || true
    else
      die "Config fehlt: ${CONFIG_FILE} (und Example fehlt/leer: ${EXAMPLE_FILE})"
    fi
  fi

  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"

  # Defaults (safe fallback; should normally come from config)
  : "${LOG_DIR:=/var/log/${APP}}"
  : "${EXPORT_DIR:=/var/log/${APP}/export}"

  : "${SUMMARY_INTERVAL_SEC:=300}"
  : "${PING_BURST_INTERVAL_SEC:=20}"
  : "${MTR_INTERVAL_SEC:=1800}"
  : "${IPERF_UDP_INTERVAL_SEC:=900}"
  : "${SPEEDTEST_INTERVAL_SEC:=3600}"

  # Create directories now (avoid later write failures)
  mkdirp "${LOG_DIR}"
  mkdirp "${EXPORT_DIR}"
}

init_storage() {
  mkdirp "$LOG_DIR"
  mkdirp "$EXPORT_DIR"

  # 5-min CSVs
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

run_component() {
  local script="$1"
  shift || true
  [[ -x "${BASE_DIR}/components/${script}" ]] || die "Component fehlt/nicht ausführbar: ${BASE_DIR}/components/${script}"
  "${BASE_DIR}/components/${script}" "$@"
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

  local now next_ping next_summary next_mtr next_iperf next_speed
  now="$(ts_epoch)"
  next_ping="$now"
  next_summary="$now"
  next_mtr="$now"
  next_iperf="$now"
  next_speed="$now"

  while true; do
    now="$(ts_epoch)"
    [[ "${stop_requested}" -eq 1 ]] && break
    [[ "${now}" -ge "${end_ts}" ]] && break

    # Ping burst
    if [[ "${now}" -ge "${next_ping}" ]]; then
      run_component "ping_quality.sh" "${CONFIG_FILE}" || true
      next_ping=$(( now + PING_BURST_INTERVAL_SEC ))
    fi

    # DNS quality
    if [[ "${now}" -ge "${next_ping}" ]]; then
      : # (kept intentionally - ping and dns can share interval)
    fi
    if [[ "${now}" -ge $(( next_ping - PING_BURST_INTERVAL_SEC )) ]]; then
      run_component "dns_quality.sh" "${CONFIG_FILE}" || true
    fi

    # MTR snapshot
    if [[ "${now}" -ge "${next_mtr}" ]]; then
      run_component "mtr_snapshot.sh" "${CONFIG_FILE}" || true
      next_mtr=$(( now + MTR_INTERVAL_SEC ))
    fi

    # iperf UDP (optional)
    if [[ "${now}" -ge "${next_iperf}" ]]; then
      run_component "iperf_udp.sh" "${CONFIG_FILE}" || true
      next_iperf=$(( now + IPERF_UDP_INTERVAL_SEC ))
    fi

    # Speedtest
    if [[ "${now}" -ge "${next_speed}" ]]; then
      run_component "speedtest.sh" "${CONFIG_FILE}" || true
      next_speed=$(( now + SPEEDTEST_INTERVAL_SEC ))
    fi

    # Summary/report (5-min)
    if [[ "${now}" -ge "${next_summary}" ]]; then
      run_component "summary_5min.sh" "${CONFIG_FILE}" || true
      run_component "report_5min.sh" "${CONFIG_FILE}" || true
      next_summary=$(( now + SUMMARY_INTERVAL_SEC ))
    fi

    sleep 1
  done

  log_jsonl "${LOG_DIR}/events.jsonl" "{\"type\":\"stop\",\"run_id\":${run_id},\"end_ts\":${end_ts}}"

  # Final report/export attempt
  run_component "report_final.sh" "${CONFIG_FILE}" || true
}

main "$@"
