#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${BASE_DIR}/lib.sh"

APP="netwatch"
CONFIG_FILE="/etc/${APP}/${APP}.conf"
EXAMPLE_FILE="${BASE_DIR}/config.example.conf"

load_config() {
  # Auto-create config from example if missing (prevents restart loops)
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

  # Defaults
  : "${LOG_DIR:=/var/log/${APP}}"
  : "${EXPORT_DIR:=/var/log/${APP}/export}"

  : "${DURATION_HOURS:=24}"
  : "${DURATION_SEC:=}"

  : "${PING_BURST_INTERVAL_SEC:=20}"
  : "${SUMMARY_INTERVAL_SEC:=300}"
  : "${MTR_INTERVAL_SEC:=1800}"
  : "${IPERF_UDP_INTERVAL_SEC:=900}"
  : "${SPEEDTEST_INTERVAL_SEC:=3600}"

  : "${PING_BURST_COUNT:=10}"
  : "${PING_BURST_I:=0.2}"

  # Create dirs early
  mkdirp "${LOG_DIR}"
  mkdirp "${EXPORT_DIR}"
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
    echo $(( DURATION_HOURS * 3600 ))
  fi
}

# Optional components should not kill the daemon if missing
run_component_optional() {
  local script="$1"; shift || true
  if [[ -x "${BASE_DIR}/components/${script}" ]]; then
    "${BASE_DIR}/components/${script}" "$@" || true
  else
    log_jsonl "${LOG_DIR}/events.jsonl" "{\"type\":\"warn\",\"msg\":\"optional component missing\",\"component\":\"${script}\"}"
    return 0
  fi
}

# Required components must exist, but failures should not kill the daemon loop
run_component_required() {
  local script="$1"; shift || true
  [[ -x "${BASE_DIR}/components/${script}" ]] || die "Component fehlt/nicht ausführbar: ${BASE_DIR}/components/${script}"
  "${BASE_DIR}/components/${script}" "$@" || true
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

    # --- Ping burst (frequent) ---
    if [[ "${now}" -ge "${next_ping}" ]]; then
      for target in "${PING_TARGETS[@]:-1.1.1.1 8.8.8.8}"; do
        # usage: ping_quality.sh burst|summary LOG_DIR TARGET [window_s] [count] [interval]
        run_component_required "ping_quality.sh" burst "${LOG_DIR}" "${target}" "" "${PING_BURST_COUNT}" "${PING_BURST_I}"
      done
      next_ping=$(( now + PING_BURST_INTERVAL_SEC ))
    fi

    # --- 5-min Summary window ---
    if [[ "${now}" -ge "${next_summary}" ]]; then
      # ping summary per target
      for target in "${PING_TARGETS[@]:-1.1.1.1 8.8.8.8}"; do
        run_component_required "ping_quality.sh" summary "${LOG_DIR}" "${target}" "${SUMMARY_INTERVAL_SEC}"
      done

      # dns summary-style probes (one shot that writes rows tagged with window_s)
      local rr="A"
      for resolver in "${LOCAL_DNS:-192.168.100.4}" "${UPSTREAM_DNS[@]:-1.1.1.1 8.8.8.8}"; do
        # usage: dns_quality.sh LOG_DIR window_s RESOLVER domain1 domain2 ...
        run_component_required "dns_quality.sh" "${LOG_DIR}" "${SUMMARY_INTERVAL_SEC}" "${resolver}" "${DNS_TEST_DOMAINS[@]:-google.com cloudflare.com github.com heise.de}"
      done

      # optional AAAA test pass (if your component supports it via config, it will do it; if not, harmless)
      next_summary=$(( now + SUMMARY_INTERVAL_SEC ))
    fi

    # --- MTR snapshot (less frequent) ---
    if [[ "${now}" -ge "${next_mtr}" ]]; then
      for target in "${PING_TARGETS[@]:-1.1.1.1 8.8.8.8}"; do
        # usage: mtr_snapshot.sh LOG_DIR TARGET
        run_component_required "mtr_snapshot.sh" "${LOG_DIR}" "${target}"
      done
      next_mtr=$(( now + MTR_INTERVAL_SEC ))
    fi

    # --- iperf UDP (optional) ---
    if [[ "${now}" -ge "${next_iperf}" ]]; then
      # If server empty, component will just exit 0 (see iperf_udp.sh below)
      run_component_optional "iperf_udp.sh" "${LOG_DIR}" "${IPERF3_SERVER:-}" "${IPERF3_PORT:-5201}" "${IPERF3_UDP_BW:-5M}" "${IPERF3_UDP_TIME:-30}"
      next_iperf=$(( now + IPERF_UDP_INTERVAL_SEC ))
    fi

    # --- Speedtest (optional) ---
    if [[ "${now}" -ge "${next_speed}" ]]; then
      # We don't know your component signature; most versions take LOG_DIR.
      # If your speedtest.sh expects different args, it should print usage but won't kill daemon due to || true inside wrapper.
      run_component_optional "speedtest.sh" "${LOG_DIR}" "${SPEEDTEST_TIMEOUT_SEC:-60}"
      next_speed=$(( now + SPEEDTEST_INTERVAL_SEC ))
    fi

    sleep 1
  done

  log_jsonl "${LOG_DIR}/events.jsonl" "{\"type\":\"stop\",\"run_id\":${run_id},\"end_ts\":${end_ts}}"

  # Final report (optional)
  run_component_optional "report_final.sh" "${LOG_DIR}" "${EXPORT_DIR}"
}

main "$@"
