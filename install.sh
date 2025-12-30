#!/usr/bin/env bash
set -euo pipefail

APP="netwatch"
SRC_DIR="src"
PKG_DIR="packaging"

INSTALL_DIR="/usr/local/lib/${APP}"
RUNNER="/usr/local/sbin/${APP}-run"
CTL="/usr/local/bin/${APP}"
SYSTEMD_UNIT="/etc/systemd/system/${APP}.service"
LOGROTATE_DST="/etc/logrotate.d/${APP}"
CONF_DIR="/etc/${APP}"
CONF_FILE="${CONF_DIR}/${APP}.conf"

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Bitte sudo nutzen."; exit 1; }; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
die() { echo "❌ $*" >&2; exit 1; }
info() { echo "➡️  $*"; }

require_files() {
  [[ -d "${SRC_DIR}" ]] || die "Fehlt: ${SRC_DIR}/"
  [[ -d "${PKG_DIR}" ]] || die "Fehlt: ${PKG_DIR}/"

  [[ -f "${SRC_DIR}/${APP}d.sh" ]] || die "Fehlt: ${SRC_DIR}/${APP}d.sh"
  [[ -f "${SRC_DIR}/lib.sh" ]] || die "Fehlt: ${SRC_DIR}/lib.sh"
  [[ -f "${SRC_DIR}/config.example.conf" ]] || die "Fehlt: ${SRC_DIR}/config.example.conf"
  [[ -s "${SRC_DIR}/config.example.conf" ]] || die "src/config.example.conf ist leer (0 Byte) – bitte füllen!"

  [[ -d "${SRC_DIR}/components" ]] || die "Fehlt: ${SRC_DIR}/components/"
  [[ -f "${SRC_DIR}/components/ping_quality.sh" ]] || die "Fehlt: ${SRC_DIR}/components/ping_quality.sh"
  [[ -f "${SRC_DIR}/components/dns_quality.sh" ]] || die "Fehlt: ${SRC_DIR}/components/dns_quality.sh"
  [[ -f "${SRC_DIR}/components/mtr_snapshot.sh" ]] || die "Fehlt: ${SRC_DIR}/components/mtr_snapshot.sh"
  [[ -f "${SRC_DIR}/components/speedtest.sh" ]] || die "Fehlt: ${SRC_DIR}/components/speedtest.sh"
  # iperf_udp.sh is optional but recommended
  if [[ ! -f "${SRC_DIR}/components/iperf_udp.sh" ]]; then
    info "Hinweis: ${SRC_DIR}/components/iperf_udp.sh fehlt (optional)."
  fi

  [[ -d "${SRC_DIR}/report" ]] || die "Fehlt: ${SRC_DIR}/report/"
  [[ -f "${SRC_DIR}/report/make_reports.sh" ]] || die "Fehlt: ${SRC_DIR}/report/make_reports.sh"
  [[ -f "${SRC_DIR}/report/export_bundle.sh" ]] || die "Fehlt: ${SRC_DIR}/report/export_bundle.sh"

  [[ -f "${PKG_DIR}/${APP}.service" ]] || die "Fehlt: ${PKG_DIR}/${APP}.service"
  [[ -f "${PKG_DIR}/logrotate.${APP}" ]] || die "Fehlt: ${PKG_DIR}/logrotate.${APP}"
}

install_deps_debian() {
  export DEBIAN_FRONTEND=noninteractive
  have_cmd apt-get || die "apt-get nicht gefunden. Dieses install.sh ist für Debian/Ubuntu gedacht."

  info "APT update…"
  apt-get update -y

  # Heal broken dpkg state if any
  info "DPKG heal (falls vorher etwas hängen blieb)…"
  apt-get -y -f install || true

  # Speedtest: avoid speedtest-cli collision with Ookla speedtest package
  if dpkg -s speedtest-cli >/dev/null 2>&1; then
    info "Entferne speedtest-cli (kollidiert mit Ookla speedtest /usr/bin/speedtest)…"
    apt-get purge -y speedtest-cli || true
    apt-get -y -f install || true
  fi

  local pkgs=(
    coreutils
    gawk
    iputils-ping
    mtr-tiny
    dnsutils
    iperf3
    jq
    ca-certificates
    curl
  )

  # Prefer Ookla speedtest if not present; do NOT install speedtest-cli.
  if ! dpkg -s speedtest >/dev/null 2>&1; then
    pkgs+=(speedtest)
  fi

  info "Installiere Pakete: ${pkgs[*]}"
  apt-get install -y "${pkgs[@]}" || true

  # Final heal
  apt-get -y -f install || true
}

install_files() {
  info "Installiere Dateien nach ${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"

  if have_cmd rsync; then
    rsync -a "${SRC_DIR}/" "${INSTALL_DIR}/"
  else
    cp -a "${SRC_DIR}/." "${INSTALL_DIR}/"
  fi

  # Ensure scripts executable
  find "${INSTALL_DIR}" -type f -name "*.sh" -exec chmod 0755 {} \;

  # Ensure example config exists and is NOT empty
  [[ -f "${INSTALL_DIR}/config.example.conf" ]] || die "Fehlt nach Copy: ${INSTALL_DIR}/config.example.conf"
  [[ -s "${INSTALL_DIR}/config.example.conf" ]] || die "Installierte Example-Config ist leer: ${INSTALL_DIR}/config.example.conf"

  # Install install.sh itself for uninstall/upgrades
  info "Installiere Installer für Uninstall/Upgrade: ${INSTALL_DIR}/install.sh"
  if [[ -f "./install.sh" ]]; then
    cp "./install.sh" "${INSTALL_DIR}/install.sh"
  else
    cp "$0" "${INSTALL_DIR}/install.sh" || true
  fi
  chmod 0755 "${INSTALL_DIR}/install.sh"

  # Ownership hardening
  chown -R root:root "${INSTALL_DIR}" || true
  chmod 0644 "${INSTALL_DIR}/config.example.conf" || true

  info "Installiere Runner: ${RUNNER}"
  cat > "${RUNNER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${INSTALL_DIR}/${APP}d.sh"
EOF
  chmod 0755 "${RUNNER}"

  info "Installiere Control-CLI: ${CTL}"
  cat > "${CTL}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

svc="netwatch.service"
BASE="/usr/local/lib/netwatch"

usage() {
  cat <<USAGE
Usage:
  netwatch start|stop|restart|status
  netwatch enable|disable
  netwatch logs                 (journalctl -u netwatch -f)
  netwatch logs-tail [N]        (journalctl -u netwatch -n N)
  netwatch report               (create TXT/CSV/HTML report bundle folder)
  netwatch export               (report + tar.gz + sha256)
USAGE
}

cmd="${1:-}"
case "$cmd" in
  start|stop|restart|status|enable|disable)
    exec systemctl "$cmd" "$svc"
    ;;
  logs)
    exec journalctl -u "$svc" -f --no-pager
    ;;
  logs-tail)
    n="${2:-200}"
    exec journalctl -u "$svc" -n "$n" --no-pager
    ;;
  report)
    exec "${BASE}/report/make_reports.sh"
    ;;
  export)
    exec "${BASE}/report/export_bundle.sh"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "Unbekannter Befehl: $cmd"
    usage
    exit 2
    ;;
esac
EOF
  chmod 0755 "${CTL}"
}

install_config() {
  info "Konfiguration…"
  mkdir -p "${CONF_DIR}"

  if [[ ! -f "${CONF_FILE}" ]]; then
    info "Erzeuge Default-Config: ${CONF_FILE}"
    cp "${INSTALL_DIR}/config.example.conf" "${CONF_FILE}"
    chmod 0644 "${CONF_FILE}" || true
    chown root:root "${CONF_FILE}" || true
  else
    info "Config existiert bereits, lasse unverändert: ${CONF_FILE}"
  fi

  # Ensure log dirs exist
  mkdir -p /var/log/netwatch /var/log/netwatch/export
  chmod 0755 /var/log/netwatch /var/log/netwatch/export || true
}

install_logrotate() {
  info "Logrotate: ${LOGROTATE_DST}"
  install -m 0644 "${PKG_DIR}/logrotate.${APP}" "${LOGROTATE_DST}"
}

install_systemd() {
  have_cmd systemctl || die "systemctl nicht gefunden – systemd erforderlich."

  info "Systemd Unit: ${SYSTEMD_UNIT}"
  sed "s|@@RUNNER@@|${RUNNER}|g" "${PKG_DIR}/${APP}.service" > "${SYSTEMD_UNIT}"

  systemctl daemon-reload
  systemctl enable "${APP}.service"
  systemctl restart "${APP}.service" || systemctl start "${APP}.service"
}

uninstall_all() {
  local purge="${1:-false}"

  if have_cmd systemctl; then
    systemctl disable --now "${APP}.service" 2>/dev/null || true
    rm -f "${SYSTEMD_UNIT}"
    systemctl daemon-reload 2>/dev/null || true
  fi

  rm -f "${CTL}" "${RUNNER}" "${LOGROTATE_DST}"
  rm -rf "${INSTALL_DIR}"

  if [[ "${purge}" == "true" ]]; then
    echo "🧹 Purge: entferne Config + Logs"
    rm -rf "${CONF_DIR}"
    rm -rf /var/log/netwatch
  else
    echo "Uninstall fertig. Config/Logs bleiben:"
    echo "  ${CONF_FILE}"
    echo "  /var/log/netwatch/"
  fi
}

usage() {
  cat <<USAGE
Usage:
  sudo bash install.sh              Install/upgrade
  sudo bash install.sh --uninstall  Remove binaries/service (keep config/logs)
  sudo bash install.sh --purge      Remove everything incl. config/logs
USAGE
}

main() {
  need_root

  case "${1:-}" in
    --uninstall) uninstall_all false; exit 0 ;;
    --purge)     uninstall_all true; exit 0 ;;
    "" ) ;;
    * ) usage; exit 2 ;;
  esac

  require_files
  install_deps_debian
  install_files
  install_config
  install_logrotate
  install_systemd

  echo "✅ netwatch installiert."
  echo "Config: ${CONF_FILE}"
  echo "Status: netwatch status"
  echo "Logs: netwatch logs"
  echo "Report: netwatch report"
  echo "Export: netwatch export"
  echo "Uninstall: sudo bash ${INSTALL_DIR}/install.sh --uninstall"
  echo "Purge: sudo bash ${INSTALL_DIR}/install.sh --purge"
}

main "$@"
