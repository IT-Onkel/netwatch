#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

# Creates:
#  - REPORT.md (human-friendly)
#  - REPORT.txt (plain text)
#  - metrics_summary.json (structured)

main() {
  local log_dir="${1:-}"
  local export_dir="${2:-}"
  [[ -n "$log_dir" && -d "$log_dir" ]] || die "usage: report.sh LOG_DIR EXPORT_DIR"

  mkdirp "$export_dir"

  local now iso host
  iso="$(ts_iso)"
  host="$(hostname -f 2>/dev/null || hostname)"

  # Ping stats
  # Columns: time_iso,window_s,target,sent,received,loss_pct,rtt_min_ms,rtt_avg_ms,rtt_max_ms,rtt_mdev_ms
  local ping_rows
  ping_rows="$(awk -F',' 'NR>1{print}' "${log_dir}/ping_5min.csv" 2>/dev/null || true)"

  local ping_worst_loss ping_avg_loss ping_worst_rtt
  ping_worst_loss="$(awk -F',' 'NR>1{if($6+0>m)m=$6} END{print (m==""?0:m)}' "${log_dir}/ping_5min.csv" 2>/dev/null || echo 0)"
  ping_avg_loss="$(awk -F',' 'NR>1{sum+=$6; n++} END{if(n>0) printf "%.2f", sum/n; else print ""}' "${log_dir}/ping_5min.csv" 2>/dev/null || true)"
  ping_worst_rtt="$(awk -F',' 'NR>1{if($9+0>m)m=$9} END{print (m==""?"":m)}' "${log_dir}/ping_5min.csv" 2>/dev/null || true)"

  # DNS stats
  # Columns: time_iso,window_s,resolver,domain,rr,status,qtime_ms,token
  local dns_timeouts dns_servfail dns_ok
  dns_timeouts="$(awk -F',' 'NR>1 && $8=="TIMEOUT"{c++} END{print c+0}' "${log_dir}/dns_5min.csv" 2>/dev/null || echo 0)"
  dns_servfail="$(awk -F',' 'NR>1 && $8=="SERVFAIL"{c++} END{print c+0}' "${log_dir}/dns_5min.csv" 2>/dev/null || echo 0)"
  dns_ok="$(awk -F',' 'NR>1 && $8=="OK"{c++} END{print c+0}' "${log_dir}/dns_5min.csv" 2>/dev/null || echo 0)"

  # Speedtest stats
  local st_count st_down_avg st_up_avg st_down_min st_down_max
  st_count="$(awk -F',' 'NR>1 && $2!="none"{c++} END{print c+0}' "${log_dir}/speedtest.csv" 2>/dev/null || echo 0)"
  st_down_avg="$(awk -F',' 'NR>1 && $4!=""{sum+=$4; n++} END{if(n>0) printf "%.1f", sum/n; else print ""}' "${log_dir}/speedtest.csv" 2>/dev/null || true)"
  st_up_avg="$(awk -F',' 'NR>1 && $5!=""{sum+=$5; n++} END{if(n>0) printf "%.1f", sum/n; else print ""}' "${log_dir}/speedtest.csv" 2>/dev/null || true)"
  st_down_min="$(awk -F',' 'NR>1 && $4!=""{if(min==""||$4+0<min)min=$4} END{print min}' "${log_dir}/speedtest.csv" 2>/dev/null || true)"
  st_down_max="$(awk -F',' 'NR>1 && $4!=""{if($4+0>max)max=$4} END{print max}' "${log_dir}/speedtest.csv" 2>/dev/null || true)"

  # Simple quality rating (human-friendly)
  local rating rationale
  rating="GRÜN"
  rationale=()

  # thresholds (tunable)
  if [[ -n "$ping_avg_loss" ]] && awk "BEGIN{exit !($ping_avg_loss>=1.0)}"; then
    rating="ROT"; rationale+=("Durchschnittlicher Paketverlust >= 1% (kritisch für VoIP/VPN).")
  elif [[ -n "$ping_avg_loss" ]] && awk "BEGIN{exit !($ping_avg_loss>=0.3)}"; then
    [[ "$rating" != "ROT" ]] && rating="GELB"
    rationale+=("Paketverlust >= 0,3% (kann VoIP/DNS spürbar stören).")
  fi

  if [[ "$dns_timeouts" -gt 0 ]]; then
    [[ "$rating" == "GRÜN" ]] && rating="GELB"
    rationale+=("DNS-Timeouts wurden gemessen (Hinweis auf Mikro-Aussetzer/Jitter/Packet-Loss).")
  fi

  if [[ -n "$ping_worst_rtt" ]] && awk "BEGIN{exit !($ping_worst_rtt>=200)}"; then
    [[ "$rating" != "ROT" ]] && rating="GELB"
    rationale+=("Hohe Latenz-Spitzen (RTT max >= 200ms) deuten auf Überlast/Bufferbloat hin.")
  fi

  # Write structured JSON
  cat > "${export_dir}/metrics_summary.json" <<JSON
{
  "generated_at": "$(ts_iso)",
  "host": "$(printf '%s' "$host" | sed 's/"/\\"/g')",
  "ping": { "avg_loss_pct": "${ping_avg_loss}", "worst_loss_pct": "${ping_worst_loss}", "worst_rtt_max_ms": "${ping_worst_rtt}" },
  "dns": { "ok": ${dns_ok}, "timeouts": ${dns_timeouts}, "servfail": ${dns_servfail} },
  "speedtest": { "count": ${st_count}, "down_avg_mbps": "${st_down_avg}", "up_avg_mbps": "${st_up_avg}", "down_min_mbps": "${st_down_min}", "down_max_mbps": "${st_down_max}" },
  "rating": "$(printf '%s' "$rating" | sed 's/"/\\"/g')"
}
JSON

  # Human report (Markdown + text)
  {
    echo "# netwatch – Internet-Qualitätsbericht"
    echo
    echo "- Zeitpunkt: **${iso}**"
    echo "- Messhost: **${host}**"
    echo "- Bewertung: **${rating}**"
    echo
    echo "## Kurzfazit"
    if [[ "${#rationale[@]}" -eq 0 ]]; then
      echo "- Keine auffälligen Qualitätsprobleme im Messzeitraum festgestellt."
    else
      for r in "${rationale[@]}"; do echo "- ${r}"; done
    fi
    echo
    echo "## Paketverlust & Latenz (Ping)"
    echo "- Ø Paketverlust: **${ping_avg_loss:-n/a}%**"
    echo "- Max Paketverlust (5-Min-Fenster): **${ping_worst_loss:-n/a}%**"
    echo "- Max Latenz-Spitze (RTT max): **${ping_worst_rtt:-n/a} ms**"
    echo
    echo "## DNS-Qualität"
    echo "- OK: **${dns_ok}**"
    echo "- Timeouts: **${dns_timeouts}**"
    echo "- SERVFAIL: **${dns_servfail}**"
    echo
    echo "## Speedtests (TCP-Durchsatz)"
    if [[ "$st_count" -gt 0 ]]; then
      echo "- Anzahl: **${st_count}**"
      echo "- Download Ø: **${st_down_avg:-n/a} Mbit/s** (min: ${st_down_min:-n/a}, max: ${st_down_max:-n/a})"
      echo "- Upload Ø: **${st_up_avg:-n/a} Mbit/s**"
      echo
      echo "> Hinweis: Speedtests zeigen primär TCP-Durchsatz. Paketverlust/Jitter kann VoIP/VPN stören, auch wenn Speedtests gut aussehen."
    else
      echo "- Kein Speedtest verfügbar (Tool nicht installiert oder nicht ausführbar)."
    fi
    echo
    echo "## Beweismaterial (Dateien)"
    echo "- Ping 5-Min-CSV: \`${log_dir}/ping_5min.csv\`"
    echo "- DNS 5-Min-CSV: \`${log_dir}/dns_5min.csv\`"
    echo "- Ping Raw Bursts: \`${log_dir}/ping_bursts.log\`"
    echo "- MTR Snapshots: \`${log_dir}/mtr/\`"
    echo "- Speedtests: \`${log_dir}/speedtest.csv\`"
    echo "- iperf UDP: \`${log_dir}/iperf/\` (falls konfiguriert)"
  } > "${export_dir}/REPORT.md"

  # Plain text copy
  sed 's/\*\*//g' "${export_dir}/REPORT.md" > "${export_dir}/REPORT.txt"

  echo "OK: Report generated in ${export_dir}"
}

main "$@"
