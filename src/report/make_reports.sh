#!/usr/bin/env bash
set -euo pipefail
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
  source "$CONF"
fi

# defaults if not in config
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

grade() {
  local value="$1" warn="$2" fail="$3" mode="${4:-highbad}"
  # highbad: higher is worse; lowbad: lower is worse
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
# ---------------------------
ping_csv="${LOG_DIR}/ping_5min.csv"
ping_targets=""
ping_loss_p95=""
ping_rtt_p95=""
ping_jitter_p95=""

if [[ -f "$ping_csv" ]]; then
  ping_targets="$(awk -F',' 'NR>1{t[$3]=1} END{for(k in t) print k}' "$ping_csv" | sort | tr '\n' ' ' | sed 's/ *$//')"
  # Use p95 for loss and rtt_avg and mdev (as jitter-ish)
  ping_loss_p95="$(awk -F',' 'NR>1 && $6!=""{print $6}' "$ping_csv" | percentile 95)"
  ping_rtt_p95="$(awk -F',' 'NR>1 && $8!=""{print $8}' "$ping_csv" | percentile 95)"
  ping_jitter_p95="$(awk -F',' 'NR>1 && $10!=""{print $10}' "$ping_csv" | percentile 95)"
fi

g_ping_loss="$(grade "$ping_loss_p95" "$TH_PING_LOSS_PCT_WARN" "$TH_PING_LOSS_PCT_FAIL" highbad)"
g_ping_rtt="$(grade "$ping_rtt_p95" "$TH_PING_RTT_AVG_MS_WARN" "$TH_PING_RTT_AVG_MS_FAIL" highbad)"
g_ping_jit="$(grade "$ping_jitter_p95" "$TH_PING_JITTER_MS_WARN" "$TH_PING_JITTER_MS_FAIL" highbad)"

# ---------------------------
# DNS summary from dns_5min.csv
# ---------------------------
dns_csv="${LOG_DIR}/dns_5min.csv"
dns_timeout_pct=""
dns_qtime_p95=""
dns_total=""

if [[ -f "$dns_csv" ]]; then
  dns_total="$(awk -F',' 'NR>1{c++} END{print c+0}' "$dns_csv")"
  dns_timeouts="$(awk -F',' 'NR>1 && $6=="TIMEOUT"{c++} END{print c+0}' "$dns_csv")"
  dns_timeout_pct="$(awk -v t="$dns_total" -v to="$dns_timeouts" 'BEGIN{ if(t==0) print ""; else printf "%.2f", (to/t)*100 }')"
  dns_qtime_p95="$(awk -F',' 'NR>1 && $7!=""{print $7}' "$dns_csv" | percentile 95)"
fi

g_dns_to="$(grade "$dns_timeout_pct" "$TH_DNS_TIMEOUT_PCT_WARN" "$TH_DNS_TIMEOUT_PCT_FAIL" highbad)"
g_dns_qt="$(grade "$dns_qtime_p95" "$TH_DNS_QTIME_MS_WARN" "$TH_DNS_QTIME_MS_FAIL" highbad)"

# ---------------------------
# Speedtest summary from speedtest.csv
# ---------------------------
st_csv="${LOG_DIR}/speedtest.csv"
st_runs=""
st_ok=""
st_down_med=""
st_up_med=""
st_ping_med=""

if [[ -f "$st_csv" ]]; then
  st_runs="$(awk -F',' 'NR>1{c++} END{print c+0}' "$st_csv")"
  st_ok="$(awk -F',' 'NR>1 && $8=="ok"{c++} END{print c+0}' "$st_csv")"

  st_down_med="$(awk -F',' 'NR>1 && $4!=""{print $4}' "$st_csv" | median)"
  st_up_med="$(awk -F',' 'NR>1 && $5!=""{print $5}' "$st_csv" | median)"
  st_ping_med="$(awk -F',' 'NR>1 && $3!=""{print $3}' "$st_csv" | median)"
fi

g_st_down="$(grade "$st_down_med" "$TH_SPEED_DOWN_MBPS_WARN" "$TH_SPEED_DOWN_MBPS_FAIL" lowbad)"
g_st_up="$(grade "$st_up_med" "$TH_SPEED_UP_MBPS_WARN" "$TH_SPEED_UP_MBPS_FAIL" lowbad)"
g_st_ping="$(grade "$st_ping_med" "$TH_SPEED_PING_MS_WARN" "$TH_SPEED_PING_MS_FAIL" highbad)"

# ---------------------------
# iperf UDP summary from iperf_udp.csv
# ---------------------------
ip_csv="${LOG_DIR}/iperf_udp.csv"
ip_runs=""
ip_ok=""
ip_bw_med=""
ip_jit_p95=""
ip_loss_p95=""

if [[ -f "$ip_csv" ]]; then
  ip_runs="$(awk -F',' 'NR>1{c++} END{print c+0}' "$ip_csv")"
  ip_ok="$(awk -F',' 'NR>1 && $8=="ok"{c++} END{print c+0}' "$ip_csv")"
  ip_bw_med="$(awk -F',' 'NR>1 && $4!=""{print $4}' "$ip_csv" | median)"
  ip_jit_p95="$(awk -F',' 'NR>1 && $5!=""{print $5}' "$ip_csv" | percentile 95)"
  ip_loss_p95="$(awk -F',' 'NR>1 && $6!=""{print $6}' "$ip_csv" | percentile 95)"
fi

g_ip_jit="$(grade "$ip_jit_p95" "$TH_IPERF_JITTER_MS_WARN" "$TH_IPERF_JITTER_MS_FAIL" highbad)"
g_ip_loss="$(grade "$ip_loss_p95" "$TH_IPERF_LOSS_PCT_WARN" "$TH_IPERF_LOSS_PCT_FAIL" highbad)"

# Overall headline (simple worst-of)
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
