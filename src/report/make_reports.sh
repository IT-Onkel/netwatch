#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${BASE_DIR}/../lib.sh"

LOG_DIR="${1:-/var/log/netwatch}"
EXPORT_DIR="${2:-/var/log/netwatch/export}"
CONF="/etc/netwatch/netwatch.conf"

mkdirp "$EXPORT_DIR"

# load thresholds if config exists
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF" || true
fi

# defaults if not in config (keep existing names for compatibility)
: "${TH_PING_LOSS_PCT_WARN:=1}"
: "${TH_PING_LOSS_PCT_FAIL:=3}"
: "${TH_PING_RTT_AVG_MS_WARN:=60}"
: "${TH_PING_RTT_AVG_MS_FAIL:=120}"
: "${TH_PING_JITTER_MS_WARN:=15}"
: "${TH_PING_JITTER_MS_FAIL:=30}"

: "${TH_DNS_TIMEOUT_PCT_WARN:=1}"
: "${TH_DNS_TIMEOUT_PCT_FAIL:=3}"
: "${TH_DNS_QTIME_MS_WARN:=150}"
: "${TH_DNS_QTIME_MS_FAIL:=300}"

: "${TH_SPEED_DOWN_MBPS_WARN:=20}"
: "${TH_SPEED_DOWN_MBPS_FAIL:=10}"
: "${TH_SPEED_UP_MBPS_WARN:=5}"
: "${TH_SPEED_UP_MBPS_FAIL:=2}"
: "${TH_SPEED_PING_MS_WARN:=60}"
: "${TH_SPEED_PING_MS_FAIL:=120}"

: "${TH_IPERF_LOSS_PCT_WARN:=1}"
: "${TH_IPERF_LOSS_PCT_FAIL:=3}"
: "${TH_IPERF_JITTER_MS_WARN:=15}"
: "${TH_IPERF_JITTER_MS_FAIL:=30}"

ts="$(ts_iso)"
out_h="${EXPORT_DIR}/report_human.md"
out_t="${EXPORT_DIR}/report_tech.md"
out_j="${EXPORT_DIR}/report_evidence.json"

# ---------------------------
# Helpers (robust numeric parsing)
# ---------------------------

# Print a normalized number or nothing.
# - converts comma decimal to dot
# - strips non-number chars (keeps digits, dot, minus)
norm_num() {
  local s="${1:-}"
  s="${s//,/.}"
  # keep digits, dot, minus only
  s="$(printf "%s" "$s" | tr -cd '0-9.-')"
  # reject empty / only "-" / "." etc.
  if [[ -z "$s" || "$s" == "-" || "$s" == "." || "$s" == "-." ]]; then
    printf ""
    return 0
  fi
  printf "%s" "$s"
}

# Read numbers from stdin, normalize, print only valid ones (one per line)
filter_nums() {
  while IFS= read -r line; do
    n="$(norm_num "$line")"
    [[ -n "$n" ]] && printf "%s\n" "$n"
  done
}

# Safe wrapper around percentile/median: returns empty if no valid numbers
safe_percentile() {
  local p="$1"
  local tmp
  tmp="$(mktemp)"
  filter_nums >"$tmp" || true
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    printf ""
    return 0
  fi
  # percentile function comes from lib.sh
  percentile "$p" <"$tmp" || true
  rm -f "$tmp"
}

safe_median() {
  local tmp
  tmp="$(mktemp)"
  filter_nums >"$tmp" || true
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    printf ""
    return 0
  fi
  median <"$tmp" || true
  rm -f "$tmp"
}

# grade() compatible with existing behavior, but normalizes inputs to avoid awk issues
grade() {
  local value warn fail mode="${4:-highbad}"
  value="$(norm_num "${1:-}")"
  warn="$(norm_num "${2:-}")"
  fail="$(norm_num "${3:-}")"

  awk -v v="$value" -v w="$warn" -v f="$fail" -v m="$mode" '
    BEGIN{
      if(v=="" || w=="" || f==""){print "UNKNOWN"; exit 0}
      if(m=="highbad"){
        if(v>=f) print "FAIL";
        else if(v>=w) print "WARN";
        else print "OK";
      } else {
        if(v<=f) print "FAIL";
        else if(v<=w) print "WARN";
        else print "OK";
      }
    }'
}

# ---------------------------
# PING summary from ping_5min.csv
# Header: time_iso,window_s,target,sent,received,loss_pct,rtt_min_ms,rtt_avg_ms,rtt_max_ms,rtt_mdev_ms
# ---------------------------
ping_csv="${LOG_DIR}/ping_5min.csv"
ping_targets=""
ping_loss_p95=""
ping_rtt_p95=""
ping_jitter_p95=""

if [[ -f "$ping_csv" ]]; then
  ping_targets="$(awk -F',' 'NR>1{t[$3]=1} END{for(k in t) print k}' "$ping_csv" | sort | tr '\n' ' ' | sed 's/ *$//')"
  ping_loss_p95="$(awk -F',' 'NR>1{print $6}' "$ping_csv" | safe_percentile 95)"
  ping_rtt_p95="$(awk -F',' 'NR>1{print $8}' "$ping_csv" | safe_percentile 95)"
  ping_jitter_p95="$(awk -F',' 'NR>1{print $10}' "$ping_csv" | safe_percentile 95)"
fi

g_ping_loss="$(grade "$ping_loss_p95" "$TH_PING_LOSS_PCT_WARN" "$TH_PING_LOSS_PCT_FAIL" highbad)"
g_ping_rtt="$(grade "$ping_rtt_p95" "$TH_PING_RTT_AVG_MS_WARN" "$TH_PING_RTT_AVG_MS_FAIL" highbad)"
g_ping_jit="$(grade "$ping_jitter_p95" "$TH_PING_JITTER_MS_WARN" "$TH_PING_JITTER_MS_FAIL" highbad)"

# ---------------------------
# DNS summary from dns_5min.csv
# Header: time_iso,window_s,resolver,domain,rr,status,qtime_ms,token
# status may be TIMEOUT/NOERROR/etc (case-insensitive)
# ---------------------------
dns_csv="${LOG_DIR}/dns_5min.csv"
dns_timeout_pct=""
dns_qtime_p95=""
dns_total="0"
dns_timeouts="0"

if [[ -f "$dns_csv" ]]; then
  dns_total="$(awk -F',' 'NR>1{c++} END{print c+0}' "$dns_csv")"
  dns_timeouts="$(awk -F',' 'NR>1{ s=toupper($6); if(s=="TIMEOUT") c++ } END{print c+0}' "$dns_csv")"
  dns_timeout_pct="$(awk -v t="$dns_total" -v to="$dns_timeouts" 'BEGIN{ if(t==0) print ""; else printf "%.2f", (to/t)*100 }')"
  dns_qtime_p95="$(awk -F',' 'NR>1{print $7}' "$dns_csv" | safe_percentile 95)"
fi

g_dns_to="$(grade "$dns_timeout_pct" "$TH_DNS_TIMEOUT_PCT_WARN" "$TH_DNS_TIMEOUT_PCT_FAIL" highbad)"
g_dns_qt="$(grade "$dns_qtime_p95" "$TH_DNS_QTIME_MS_WARN" "$TH_DNS_QTIME_MS_FAIL" highbad)"

# ---------------------------
# Speedtest summary from speedtest.csv
# Header: time_iso,provider,ping_ms,down_mbps,up_mbps,packet_loss,result_url,status,error
# status is col 8
# ---------------------------
st_csv="${LOG_DIR}/speedtest.csv"
st_runs="0"
st_ok="0"
st_down_med=""
st_up_med=""
st_ping_med=""

if [[ -f "$st_csv" ]]; then
  st_runs="$(awk -F',' 'NR>1{c++} END{print c+0}' "$st_csv")"
  st_ok="$(awk -F',' 'NR>1{ s=tolower($8); if(s=="ok") c++ } END{print c+0}' "$st_csv")"

  st_down_med="$(awk -F',' 'NR>1{print $4}' "$st_csv" | safe_median)"
  st_up_med="$(awk -F',' 'NR>1{print $5}' "$st_csv" | safe_median)"
  st_ping_med="$(awk -F',' 'NR>1{print $3}' "$st_csv" | safe_median)"
fi

g_st_down="$(grade "$st_down_med" "$TH_SPEED_DOWN_MBPS_WARN" "$TH_SPEED_DOWN_MBPS_FAIL" lowbad)"
g_st_up="$(grade "$st_up_med" "$TH_SPEED_UP_MBPS_WARN" "$TH_SPEED_UP_MBPS_FAIL" lowbad)"
g_st_ping="$(grade "$st_ping_med" "$TH_SPEED_PING_MS_WARN" "$TH_SPEED_PING_MS_FAIL" highbad)"

# ---------------------------
# iperf UDP summary from iperf_udp.csv
# Current header in your daemon:
# time_iso,server,port,bw_mbps,jitter_ms,loss_pct,datagrams,status,raw_path
# status col 8
# ---------------------------
ip_csv="${LOG_DIR}/iperf_udp.csv"
ip_runs="0"
ip_ok="0"
ip_bw_med=""
ip_jit_p95=""
ip_loss_p95=""

if [[ -f "$ip_csv" ]]; then
  ip_runs="$(awk -F',' 'NR>1{c++} END{print c+0}' "$ip_csv")"
  ip_ok="$(awk -F',' 'NR>1{ s=tolower($8); if(s=="ok") c++ } END{print c+0}' "$ip_csv")"
  ip_bw_med="$(awk -F',' 'NR>1{print $4}' "$ip_csv" | safe_median)"
  ip_jit_p95="$(awk -F',' 'NR>1{print $5}' "$ip_csv" | safe_percentile 95)"
  ip_loss_p95="$(awk -F',' 'NR>1{print $6}' "$ip_csv" | safe_percentile 95)"
fi

g_ip_jit="$(grade "$ip_jit_p95" "$TH_IPERF_JITTER_MS_WARN" "$TH_IPERF_JITTER_MS_FAIL" highbad)"
g_ip_loss="$(grade "$ip_loss_p95" "$TH_IPERF_LOSS_PCT_WARN" "$TH_IPERF_LOSS_PCT_FAIL" highbad)"

# Overall headline (simple worst-of) - keep logic
overall="OK"
for g in "$g_ping_loss" "$g_ping_rtt" "$g_ping_jit" "$g_dns_to" "$g_dns_qt" "$g_st_down" "$g_st_up" "$g_st_ping" "$g_ip_jit" "$g_ip_loss"; do
  if [[ "$g" == "FAIL" ]]; then overall="FAIL"; break; fi
  if [[ "$g" == "WARN" ]]; then overall="WARN"; fi
done

# ---------------------------
# Human report
# ---------------------------
cat >"$out_h" <<EOF
# netwatch – Ergebnisübersicht (verständliche Version)

Zeitpunkt: ${ts}

**Gesamtbewertung:** ${overall}

## 1) Ping/Stabilität
Ziele: ${ping_targets:-"(keine Daten)"}  
- Paketverlust (p95): ${ping_loss_p95:-n/a}% → **${g_ping_loss}** (Warn ≥ ${TH_PING_LOSS_PCT_WARN}%, Fehler ≥ ${TH_PING_LOSS_PCT_FAIL}%)
- Latenz (p95 rtt_avg): ${ping_rtt_p95:-n/a} ms → **${g_ping_rtt}** (Warn ≥ ${TH_PING_RTT_AVG_MS_WARN}ms, Fehler ≥ ${TH_PING_RTT_AVG_MS_FAIL}ms)
- Jitter (p95 mdev): ${ping_jitter_p95:-n/a} ms → **${g_ping_jit}** (Warn ≥ ${TH_PING_JITTER_MS_WARN}ms, Fehler ≥ ${TH_PING_JITTER_MS_FAIL}ms)

## 2) DNS (Namensauflösung)
- DNS-Timeouts: ${dns_timeout_pct:-n/a}% (von ${dns_total:-0} Tests) → **${g_dns_to}** (Warn ≥ ${TH_DNS_TIMEOUT_PCT_WARN}%, Fehler ≥ ${TH_DNS_TIMEOUT_PCT_FAIL}%)
- DNS-Antwortzeit (p95 Query time): ${dns_qtime_p95:-n/a} ms → **${g_dns_qt}** (Warn ≥ ${TH_DNS_QTIME_MS_WARN}ms, Fehler ≥ ${TH_DNS_QTIME_MS_FAIL}ms)

## 3) Speedtest (Durchsatz)
Runs: ${st_ok:-0}/${st_runs:-0} erfolgreich  
- Median Download: ${st_down_med:-n/a} Mbps → **${g_st_down}** (Warn < ${TH_SPEED_DOWN_MBPS_WARN}, Fehler ≤ ${TH_SPEED_DOWN_MBPS_FAIL})
- Median Upload: ${st_up_med:-n/a} Mbps → **${g_st_up}** (Warn < ${TH_SPEED_UP_MBPS_WARN}, Fehler ≤ ${TH_SPEED_UP_MBPS_FAIL})
- Median Ping: ${st_ping_med:-n/a} ms → **${g_st_ping}**

## 4) UDP-Qualität (iperf3, optional)
Runs: ${ip_ok:-0}/${ip_runs:-0} erfolgreich  
- Median Bandbreite: ${ip_bw_med:-n/a} Mbps
- Jitter (p95): ${ip_jit_p95:-n/a} ms → **${g_ip_jit}**
- Loss (p95): ${ip_loss_p95:-n/a}% → **${g_ip_loss}**

## Wo liegen die Beweise?
- CSV Logs: /var/log/netwatch/*.csv
- Raw Outputs: /var/log/netwatch/mtr, /var/log/netwatch/iperf, /var/log/netwatch/speedtest
- Export-Bundles: /var/log/netwatch/export
EOF

# ---------------------------
# Tech report
# ---------------------------
cat >"$out_t" <<EOF
# netwatch – Technischer Report

Zeitpunkt: ${ts}

## Ping (aus ping_5min.csv)
Targets: ${ping_targets:-"(keine Daten)"}
p95 loss=%: ${ping_loss_p95:-n/a}
p95 rtt_avg_ms: ${ping_rtt_p95:-n/a}
p95 mdev_ms: ${ping_jitter_p95:-n/a}

## DNS (aus dns_5min.csv)
Tests: ${dns_total:-0}
Timeouts: ${dns_timeouts:-0}
Timeout %: ${dns_timeout_pct:-n/a}
p95 Query time ms: ${dns_qtime_p95:-n/a}

## Speedtest (aus speedtest.csv)
Runs ok/total: ${st_ok:-0}/${st_runs:-0}
median down Mbps: ${st_down_med:-n/a}
median up Mbps: ${st_up_med:-n/a}
median ping ms: ${st_ping_med:-n/a}

## iPerf UDP (aus iperf_udp.csv)
Runs ok/total: ${ip_ok:-0}/${ip_runs:-0}
median bw Mbps: ${ip_bw_med:-n/a}
p95 jitter ms: ${ip_jit_p95:-n/a}
p95 loss %: ${ip_loss_p95:-n/a}
EOF

# ---------------------------
# Evidence JSON (maschinenlesbar)
# Keep compatible output structure (strings), but make values safe
# ---------------------------
cat >"$out_j" <<EOF
{
  "time_iso": "$(printf "%s" "$ts")",
  "overall": "$(printf "%s" "$overall")",
  "ping": {
    "targets": "$(printf "%s" "${ping_targets:-}" | json_escape)",
    "loss_p95_pct": "$(printf "%s" "${ping_loss_p95:-}")",
    "rtt_p95_ms": "$(printf "%s" "${ping_rtt_p95:-}")",
    "jitter_p95_ms": "$(printf "%s" "${ping_jitter_p95:-}")",
    "grade_loss": "$(printf "%s" "$g_ping_loss")",
    "grade_rtt": "$(printf "%s" "$g_ping_rtt")",
    "grade_jitter": "$(printf "%s" "$g_ping_jit")"
  },
  "dns": {
    "tests": "$(printf "%s" "${dns_total:-0}")",
    "timeouts": "$(printf "%s" "${dns_timeouts:-0}")",
    "timeouts_pct": "$(printf "%s" "${dns_timeout_pct:-}")",
    "qtime_p95_ms": "$(printf "%s" "${dns_qtime_p95:-}")",
    "grade_timeouts": "$(printf "%s" "$g_dns_to")",
    "grade_qtime": "$(printf "%s" "$g_dns_qt")"
  },
  "speedtest": {
    "runs_total": "$(printf "%s" "${st_runs:-0}")",
    "runs_ok": "$(printf "%s" "${st_ok:-0}")",
    "down_median_mbps": "$(printf "%s" "${st_down_med:-}")",
    "up_median_mbps": "$(printf "%s" "${st_up_med:-}")",
    "ping_median_ms": "$(printf "%s" "${st_ping_med:-}")",
    "grade_down": "$(printf "%s" "$g_st_down")",
    "grade_up": "$(printf "%s" "$g_st_up")",
    "grade_ping": "$(printf "%s" "$g_st_ping")"
  },
  "iperf_udp": {
    "runs_total": "$(printf "%s" "${ip_runs:-0}")",
    "runs_ok": "$(printf "%s" "${ip_ok:-0}")",
    "bw_median_mbps": "$(printf "%s" "${ip_bw_med:-}")",
    "jitter_p95_ms": "$(printf "%s" "${ip_jit_p95:-}")",
    "loss_p95_pct": "$(printf "%s" "${ip_loss_p95:-}")",
    "grade_jitter": "$(printf "%s" "$g_ip_jit")",
    "grade_loss": "$(printf "%s" "$g_ip_loss")"
  }
}
EOF

echo "OK: wrote reports:"
echo "  $out_h"
echo "  $out_t"
echo "  $out_j"
