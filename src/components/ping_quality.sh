#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/../lib.sh"

usage() {
  die "usage: ping_quality.sh burst LOG_DIR TARGET COUNT INTERVAL  |  ping_quality.sh window LOG_DIR WINDOW_S TARGET"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  burst)
    LOG_DIR="${1:-}"; TARGET="${2:-}"; COUNT="${3:-}"; INTERVAL="${4:-}"
    [[ -n "${LOG_DIR}" && -n "${TARGET}" && -n "${COUNT}" && -n "${INTERVAL}" ]] || usage
    mkdirp "$LOG_DIR"
    out="${LOG_DIR}/ping_bursts.log"
    ts="$(ts_iso)"
    # -q is too quiet; keep parseable output line
    # We capture summary via "ping -c"
    ping -n -i "$INTERVAL" -c "$COUNT" -W 1 "$TARGET" 2>&1 | awk -v ts="$ts" -v tgt="$TARGET" '
      BEGIN{print ts " target="tgt " BEGIN"}
      {print ts " target="tgt " " $0}
      END{print ts " target="tgt " END"}
    ' >> "$out" || true
    ;;
  window)
    LOG_DIR="${1:-}"; WINDOW_S="${2:-}"; TARGET="${3:-}"
    [[ -n "${LOG_DIR}" && -n "${WINDOW_S}" && -n "${TARGET}" ]] || usage
    mkdirp "$LOG_DIR"

    # run a burst sized to window? keep small + representative: 10 pings @0.2s
    local_count=10
    local_i=0.2
    ts="$(ts_iso)"
    tmp="$(mktemp)"
    ping -n -i "$local_i" -c "$local_count" -W 1 "$TARGET" >"$tmp" 2>/dev/null || true

    # parse: transmitted, received, loss, rtt min/avg/max/mdev
    # default unknowns to empty
    sent="$(awk '/packets transmitted/{print $1}' "$tmp" | tail -n1)"
    recv="$(awk '/packets transmitted/{print $4}' "$tmp" | tail -n1)"
    loss="$(awk -F',' '/packets transmitted/{gsub(/%/,"",$3); gsub(/ /,"",$3); print $3}' "$tmp" | tail -n1)"
    rtt="$(awk -F'=' '/rtt min\/avg\/max\/mdev/{print $2}' "$tmp" | tail -n1 | tr -d ' ')"
    rtt_min=""; rtt_avg=""; rtt_max=""; rtt_mdev=""
    if [[ -n "$rtt" ]]; then
      rtt_min="$(echo "$rtt" | awk -F'/' '{print $1}')"
      rtt_avg="$(echo "$rtt" | awk -F'/' '{print $2}')"
      rtt_max="$(echo "$rtt" | awk -F'/' '{print $3}')"
      rtt_mdev="$(echo "$rtt" | awk -F'/' '{print $4}')"
    fi
    rm -f "$tmp"

    csv_append "${LOG_DIR}/ping_5min.csv" "${ts},${WINDOW_S},${TARGET},${sent:-},${recv:-},${loss:-},${rtt_min:-},${rtt_avg:-},${rtt_max:-},${rtt_mdev:-}"
    ;;
  *)
    usage
    ;;
esac
