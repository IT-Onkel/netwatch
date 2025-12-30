#!/usr/bin/env bash
set -euo pipefail
# Produces: dns_5min.csv
. "$(dirname "$0")/../lib.sh"

dns_query() {
  local resolver="$1" domain="$2" rr="$3"
  local out rc status qtime token
  rc=0
  out="$(dig @"$resolver" "$domain" "$rr" +tries=1 +time=2 +stats 2>&1)" || rc=$?

  if grep -qiE 'connection timed out|no servers could be reached' <<<"$out"; then
    token="TIMEOUT"
  elif [[ "$rc" -ne 0 ]]; then
    token="ERROR"
  else
    status="$(sed -n 's/.* status: \([A-Z]*\).*/\1/p' <<<"$out" | head -n1 || true)"
    case "${status:-}" in
      NOERROR) token="OK" ;;
      NXDOMAIN) token="NXDOMAIN" ;;
      SERVFAIL) token="SERVFAIL" ;;
      REFUSED) token="REFUSED" ;;
      *) token="UNKNOWN" ;;
    esac
  fi

  qtime="$(awk '/^;; Query time:/{print $4; exit}' <<<"$out" 2>/dev/null || true)"
  status="${status:-NA}"
  qtime="${qtime:-NA}"
  echo "${token}|${status}|${qtime}"
}

dns_summary_rows() {
  local log_dir="$1" window_s="$2" resolver="$3"
  shift 3
  local domains=("$@")
  local now_iso rr d r token status qtime

  now_iso="$(ts_iso)"
  for d in "${domains[@]}"; do
    for rr in A AAAA; do
      r="$(dns_query "$resolver" "$d" "$rr")"
      token="${r%%|*}"
      status="$(cut -d'|' -f2 <<<"$r")"
      qtime="$(cut -d'|' -f3 <<<"$r")"
      printf "%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "${now_iso}" "${window_s}" "${resolver}" "${d}" "${rr}" "${status}" "${qtime}" "${token}" \
        >> "${log_dir}/dns_5min.csv"
    done
  done
}

main() {
  local log_dir="${1:-}"
  local window_s="${2:-300}"
  local resolver="${3:-}"
  shift 3 || true
  local domains=("$@")

  [[ -n "$log_dir" && -n "$resolver" && "${#domains[@]}" -gt 0 ]] || die "usage: dns_quality.sh LOG_DIR window_s RESOLVER domain1 domain2 ..."

  dns_summary_rows "$log_dir" "$window_s" "$resolver" "${domains[@]}"
}

main "$@"
