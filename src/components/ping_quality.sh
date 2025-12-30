#!/usr/bin/env bash
set -euo pipefail
# Produces: ping_bursts.log (raw) and ping_5min.csv (summary)
. "$(dirname "$0")/../lib.sh"

ping_burst() {
  local log_dir="$1" target="$2" count="$3" interval="$4"
  {
    echo "=== PING_BURST start=$(ts_iso) target=${target} ==="
    ping -n -i "$interval" -c "$count" -w 5 "$target" || true
    echo "=== PING_BURST end=$(ts_iso) target=${target} ==="
  } >> "${log_dir}/ping_bursts.log" 2>&1
}

ping_summary_row() {
  local log_dir="$1" target="$2" window_s="$3"
  local now_iso out sent recv loss rmin ravg rmax rmdev

  now_iso="$(ts_iso)"
  out="$(ping -n -i 0.2 -c 50 -w 15 "${target}" 2>&1 || true)"

  sent="$(awk '/packets transmitted/ {print $1; exit}' <<<"$out" 2>/dev/null || echo 0)"
  recv="$(awk '/packets transmitted/ {print $4; exit}' <<<"$out" 2>/dev/null || echo 0)"
  loss="$(awk -F'[, ]+' '/packets transmitted/ {for(i=1;i<=NF;i++) if($i ~ /%/) {gsub("%","",$i); print $i; exit}}' <<<"$out" 2>/dev/null || echo "100")"

  rmin=""; ravg=""; rmax=""; rmdev=""
  if grep -qE '^rtt ' <<<"$out"; then
    local rtt
    rtt="$(awk -F'[ =/]+' '/^rtt / {print $5","$6","$7","$8; exit}' <<<"$out" 2>/dev/null || true)"
    rmin="${rtt%%,*}"
    ravg="$(cut -d, -f2 <<<"$rtt" 2>/dev/null || true)"
    rmax="$(cut -d, -f3 <<<"$rtt" 2>/dev/null || true)"
    rmdev="$(cut -d, -f4 <<<"$rtt" 2>/dev/null || true)"
  fi

  printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "${now_iso}" "${window_s}" "${target}" "${sent}" "${recv}" "${loss}" \
    "${rmin}" "${ravg}" "${rmax}" "${rmdev}" >> "${log_dir}/ping_5min.csv"
}

main() {
  local mode="${1:-}"
  local log_dir="${2:-}"
  local target="${3:-}"
  local window_s="${4:-300}"
  local count="${5:-10}"
  local interval="${6:-0.2}"

  [[ -n "$mode" && -n "$log_dir" ]] || die "usage: ping_quality.sh burst|summary LOG_DIR TARGET [window_s] [count] [interval]"

  if [[ "$mode" == "burst" ]]; then
    ping_burst "$log_dir" "$target" "$count" "$interval"
  elif [[ "$mode" == "summary" ]]; then
    ping_summary_row "$log_dir" "$target" "$window_s"
  else
    die "unknown mode: $mode"
  fi
}

main "$@"
