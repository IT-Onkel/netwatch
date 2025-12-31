#!/usr/bin/env bash
set -euo pipefail

APP="netwatch"
CONF="/etc/${APP}/${APP}.conf"
BASE="/usr/local/lib/${APP}"

die(){ echo "❌ $*" >&2; exit 1; }
info(){ echo "➡️  $*"; }

[[ -f "$CONF" ]] || die "Config fehlt: $CONF"
# shellcheck disable=SC1090
source "$CONF"

: "${LOG_DIR:=/var/log/${APP}}"
: "${EXPORT_DIR:=/var/log/${APP}/export}"

REPORT_SCRIPT="${BASE}/report/make_reports.sh"
[[ -x "$REPORT_SCRIPT" ]] || die "Report-Skript fehlt/nicht ausführbar: $REPORT_SCRIPT"

mkdir -p "$EXPORT_DIR"

ts_dir="$(date +%Y%m%d_%H%M%S)"
BUNDLE_DIR="${EXPORT_DIR}/netwatch_bundle_${ts_dir}"
mkdir -p "$BUNDLE_DIR"

info "Erzeuge Reports…"
"$REPORT_SCRIPT"

# Neuester Report-Ordner (von make_reports.sh erzeugt)
LATEST_REPORT="$(ls -1dt "${EXPORT_DIR}"/netwatch_report_* 2>/dev/null | head -n 1 || true)"
[[ -n "$LATEST_REPORT" ]] || die "Kein report-Ordner gefunden unter: ${EXPORT_DIR}/netwatch_report_*"

info "Sammle Rohdaten…"
mkdir -p "${BUNDLE_DIR}/raw"

# Wichtigste Rohdaten
cp -a "${LOG_DIR}/ping_5min.csv" "${BUNDLE_DIR}/raw/" 2>/dev/null || true
cp -a "${LOG_DIR}/dns_5min.csv"  "${BUNDLE_DIR}/raw/" 2>/dev/null || true
cp -a "${LOG_DIR}/events.jsonl"  "${BUNDLE_DIR}/raw/" 2>/dev/null || true

# Optional: Alles was mtr/iperf/speedtest ablegt
if compgen -G "${LOG_DIR}/*mtr*" >/dev/null; then cp -a ${LOG_DIR}/*mtr* "${BUNDLE_DIR}/raw/" 2>/dev/null || true; fi
if compgen -G "${LOG_DIR}/*iperf*" >/dev/null; then cp -a ${LOG_DIR}/*iperf* "${BUNDLE_DIR}/raw/" 2>/dev/null || true; fi
if compgen -G "${LOG_DIR}/*speedtest*" >/dev/null; then cp -a ${LOG_DIR}/*speedtest* "${BUNDLE_DIR}/raw/" 2>/dev/null || true; fi

info "Kopiere Reports…"
mkdir -p "${BUNDLE_DIR}/report"
cp -a "${LATEST_REPORT}/." "${BUNDLE_DIR}/report/"

info "Metadaten…"
cat > "${BUNDLE_DIR}/META.txt" <<EOF
netwatch evidence bundle
created: $(date -Is)
host: $(hostname -f 2>/dev/null || hostname)
config: ${CONF}
log_dir: ${LOG_DIR}
report_dir: ${LATEST_REPORT}
EOF

TAR="${EXPORT_DIR}/netwatch_bundle_${ts_dir}.tar.gz"
SHA="${EXPORT_DIR}/netwatch_bundle_${ts_dir}.sha256"

info "Packe Bundle: ${TAR}"
tar -C "${EXPORT_DIR}" -czf "${TAR}" "$(basename "${BUNDLE_DIR}")"

info "SHA256: ${SHA}"
sha256sum "$(basename "${TAR}")" > "${SHA}" 2>/dev/null || (cd "${EXPORT_DIR}" && sha256sum "$(basename "${TAR}")" > "$(basename "${SHA}")")

info "✅ Fertig:"
echo "  Bundle: ${TAR}"
echo "  SHA256 : ${SHA}"
echo "  Ordner : ${BUNDLE_DIR}"
