#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/../lib.sh"

usage() { die "usage: dns_quality.sh window LOG_DIR WINDOW_S RESOLVER domain1 domain2 ... [RR]"; }

cmd="${1:-}"; shift || true
[[ "$cmd" == "window" ]] || usage

LOG_DIR="${1:-}"; WINDOW_S="${2:-}"; RESOLVER="${3:-}"; shift 3 || true
[[ -n "$LOG_DIR" && -n "$WINDOW_S" && -n "$RESOLVER" ]] || usage
[[ "$#" -ge 1 ]] || usage

# optional last arg RR if looks like RR type
RR="A"
last="${*: -1}"
if [[ "$last" =~ ^(A|AAAA|TXT|NS|SOA)$ ]]; then
  RR="$last"
  set -- "${@:1:$(($#-1))}"
fi

mkdirp "$LOG_DIR"

DIG="${DIG_BIN:-}"
if [[ -z "${DIG}" ]]; then
  DIG="$(command -v dig || true)"
fi
[[ -n "$DIG" ]] || die "dig not found (install dnsutils)"

ts="$(ts_iso)"
token="$(date +%s)"
for domain in "$@"; do
  # dig output:
  # - status in header, query time in stats
  out="$("$DIG" @"$RESOLVER" "$domain" "$RR" +time=2 +tries=1 +stats 2>&1 || true)"
  status="$(echo "$out" | awk '/status:/{gsub(/,/, "", $6); print $6; exit}' || true)"
  qtime="$(echo "$out" | awk -F': ' '/Query time:/{print $2}' | awk '{print $1}' || true)"

  if echo "$out" | grep -qiE 'connection timed out|no servers could be reached'; then
    status="TIMEOUT"
  elif [[ -z "$status" ]]; then
    # could be SERVFAIL/REFUSED/etc in some variants
    status="UNKNOWN"
  fi

  csv_append "${LOG_DIR}/dns_5min.csv" "${ts},${WINDOW_S},${RESOLVER},${domain},${RR},${status},${qtime:-},${token}"
done
