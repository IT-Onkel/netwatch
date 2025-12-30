#!/usr/bin/env bash
set -euo pipefail

APP="netwatch"
CONFIG="/etc/${APP}/${APP}.conf"
LOG_DIR="/var/log/${APP}"
EXPORT_BASE="${LOG_DIR}/export"

PING_CSV="${LOG_DIR}/ping_5min.csv"
DNS_CSV="${LOG_DIR}/dns_5min.csv"
EVENTS="${LOG_DIR}/events.jsonl"

die() { echo "❌ $*" >&2; exit 1; }
info() { echo "➡️  $*"; }

[[ -f "$CONFIG" ]] || die "Config fehlt: $CONFIG"
# shellcheck disable=SC1090
source "$CONFIG"

[[ -f "$PING_CSV" ]] || die "Fehlt: $PING_CSV"
[[ -f "$DNS_CSV"  ]] || die "Fehlt: $DNS_CSV"

# --- Threshold defaults (can be overridden in config) ---
: "${THRESH_LOSS_PCT:=1.0}"
: "${THRESH_RTT_AVG_MS:=80}"
: "${THRESH_RTT_MAX_MS:=200}"
: "${THRESH_JITTER_MDEV_MS:=30}"

: "${THRESH_DNS_TIMEOUT_PCT:=1.0}"
: "${THRESH_DNS_SLOW_MS:=250}"

ts_iso="$(date -Is)"
ts_dir="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${EXPORT_BASE}/netwatch_report_${ts_dir}"
mkdir -p "$OUTDIR"

TXT="${OUTDIR}/report.txt"
CSV="${OUTDIR}/report.csv"
HTML="${OUTDIR}/report.html"

# ---------- Helpers ----------
pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if(b==0) printf "0.00"; else printf "%.2f", (a*100)/b }'; }

grade() {
  awk -v r="$1" 'BEGIN{
    if (r<=0.02) print "GRUEN";
    else if (r<=0.10) print "GELB";
    else print "ROT";
  }'
}

# ---------- Ping summary ----------
PING_SUMMARY="$(awk -F',' -v lossT="$THRESH_LOSS_PCT" -v rttA="$THRESH_RTT_AVG_MS" -v rttM="$THRESH_RTT_MAX_MS" -v jit="$THRESH_JITTER_MDEV_MS" '
NR==1{next}
{
  t=$3
  total[t]++
  loss=$6+0; rtta=$8+0; rttm=$9+0; j=$10+0
  sumLoss[t]+=loss
  if(loss>maxLoss[t]) maxLoss[t]=loss
  if(rtta>maxRttA[t]) maxRttA[t]=rtta
  if(rttm>maxRttM[t]) maxRttM[t]=rttm
  if(j>maxJ[t]) maxJ[t]=j
  bad=(loss>lossT || rtta>rttA || rttm>rttM || j>jit)
  if(bad) badCnt[t]++
  gTot++; if(bad) gBad++
}
END{
  print "PING_GLOBAL", gTot, gBad
  for(t in total){
    print "PING_TARGET", t, total[t], badCnt[t]+0, sumLoss[t], maxLoss[t]+0, maxRttA[t]+0, maxRttM[t]+0, maxJ[t]+0
  }
}' "$PING_CSV")"

PING_TOT="$(echo "$PING_SUMMARY" | awk '$1=="PING_GLOBAL"{print $2}')"
PING_BAD="$(echo "$PING_SUMMARY" | awk '$1=="PING_GLOBAL"{print $3}')"
PING_BAD_PCT="$(pct "$PING_BAD" "$PING_TOT")"
PING_BAD_RATIO="$(awk -v a="$PING_BAD" -v b="$PING_TOT" 'BEGIN{ if(b==0) print 0; else print a/b }')"

# ---------- DNS summary ----------
DNS_SUMMARY="$(awk -F',' '
NR==1{next}
{
  r=$3; st=$6; qt=$7+0
  tot[r]++
  if(st=="timeout") to[r]++
  if(qt>slowT) slow[r]++
  if(qt>maxQ[r]) maxQ[r]=qt
  gTot++; if(st=="timeout") gTo++
}
END{
  print "DNS_GLOBAL", gTot, gTo
  for(r in tot){
    print "DNS_RESOLVER", r, tot[r], to[r]+0, slow[r]+0, maxQ[r]+0
  }
}' slowT="$THRESH_DNS_SLOW_MS" "$DNS_CSV")"

DNS_TOT="$(echo "$DNS_SUMMARY" | awk '$1=="DNS_GLOBAL"{print $2}')"
DNS_TO="$(echo "$DNS_SUMMARY" | awk '$1=="DNS_GLOBAL"{print $3}')"
DNS_TO_PCT="$(pct "$DNS_TO" "$DNS_TOT")"
DNS_TO_RATIO="$(awk -v a="$DNS_TO" -v b="$DNS_TOT" 'BEGIN{ if(b==0) print 0; else print a/b }')"

# ---------- Overall grade ----------
OVERALL_RATIO="$(awk -v a="$PING_BAD_RATIO" -v b="$DNS_TO_RATIO" 'BEGIN{ if(a>b) print a; else print b }')"
OVERALL_GRADE="$(grade "$OVERALL_RATIO")"

# ---------- report.txt ----------
cat >"$TXT" <<TXT
netwatch – Internet-Qualitätsreport
Erstellt: ${ts_iso}

FAZIT (Ampel): ${OVERALL_GRADE}

Grenzwerte:
- Ping: Loss>${THRESH_LOSS_PCT}% oder RTT_avg>${THRESH_RTT_AVG_MS}ms oder RTT_max>${THRESH_RTT_MAX_MS}ms oder Jitter>${THRESH_JITTER_MDEV_MS}ms
- DNS: Timeout-Quote>${THRESH_DNS_TIMEOUT_PCT}%, langsam>${THRESH_DNS_SLOW_MS}ms

Gesamt:
- Ping schlecht in ${PING_BAD_PCT}% der 5-Min-Fenster
- DNS Timeouts in ${DNS_TO_PCT}% der Requests

Ping je Ziel:
TXT

echo "$PING_SUMMARY" | awk '
$1=="PING_TARGET"{
  t=$2; tot=$3; bad=$4; sumL=$5; maxL=$6; maxA=$7; maxM=$8; maxJ=$9;
  avg=(tot==0?0:sumL/tot);
  printf "- %-15s Fenster=%d schlecht=%d avgLoss=%.2f%% maxLoss=%.2f%% RTTavgMax=%.0fms RTTmaxMax=%.0fms JitterMax=%.0fms\n",
    t,tot,bad,avg,maxL,maxA,maxM,maxJ
}' >>"$TXT"

cat >>"$TXT" <<TXT

DNS je Resolver:
TXT

echo "$DNS_SUMMARY" | awk '
$1=="DNS_RESOLVER"{
  r=$2; tot=$3; to=$4; slow=$5; maxQ=$6;
  pct=(tot==0?0:(to*100/tot));
  printf "- %-15s req=%d timeout=%d (%.2f%%) slow=%d maxQ=%dms\n",
    r,tot,to,pct,slow,maxQ
}' >>"$TXT"

# ---------- report.csv ----------
{
  echo "type,name,total,flagged,flagged_pct,grade"
  printf "global,all,%d,%d,%.2f,%s\n" "$PING_TOT" "$PING_BAD" "$PING_BAD_PCT" "$OVERALL_GRADE"
  echo "$PING_SUMMARY" | awk -v g="$OVERALL_GRADE" '
  $1=="PING_TARGET"{ tot=$3; bad=$4; pct=(tot==0?0:(bad*100/tot));
    printf "ping,%s,%d,%d,%.2f,%s\n",$2,tot,bad,pct,g
  }'
  echo "$DNS_SUMMARY" | awk -v g="$OVERALL_GRADE" '
  $1=="DNS_RESOLVER"{ tot=$3; to=$4; pct=(tot==0?0:(to*100/tot));
    printf "dns,%s,%d,%d,%.2f,%s\n",$2,tot,to,pct,g
  }'
} >"$CSV"

# ---------- report.html ----------
COLOR="#95a5a6"
[[ "$OVERALL_GRADE" == "GRUEN" ]] && COLOR="#2ecc71"
[[ "$OVERALL_GRADE" == "GELB"  ]] && COLOR="#f1c40f"
[[ "$OVERALL_GRADE" == "ROT"   ]] && COLOR="#e74c3c"

cat >"$HTML" <<HTML
<!doctype html>
<html lang="de"><head><meta charset="utf-8">
<title>netwatch report</title>
<style>
body{font-family:system-ui,Arial;margin:24px}
.badge{display:inline-block;padding:6px 10px;border-radius:999px;color:#fff;font-weight:700;background:${COLOR}}
table{border-collapse:collapse;width:100%;margin:16px 0}
th,td{border:1px solid #ddd;padding:8px}
th{background:#f5f5f5}
</style>
</head>
<body>
<h1>netwatch – Internet-Qualitätsreport</h1>
<p>Erstellt: ${ts_iso}</p>
<p><span class="badge">Fazit: ${OVERALL_GRADE}</span></p>

<h2>Zusammenfassung</h2>
<ul>
<li>Ping schlecht: ${PING_BAD_PCT}%</li>
<li>DNS Timeouts: ${DNS_TO_PCT}%</li>
</ul>

<h2>Details</h2>
<p>Siehe <code>report.txt</code> und <code>report.csv</code> für vollständige Daten.</p>
</body></html>
HTML

( cd "$OUTDIR" && sha256sum report.txt report.csv report.html > SHA256SUMS )

info "Reports erstellt in: $OUTDIR"
