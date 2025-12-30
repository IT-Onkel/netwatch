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

# ----------------------------
# Helpers
# ----------------------------
need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Bitte sudo nutzen."; exit 1; }
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

die() { echo "❌ $*" >&2; exit 1; }

info() { echo "➡️  $*"; }

require_files() {
  [[ -d "${SRC_DIR}" ]] || die "Fehlt: ${SRC_DIR}/"
  [[ -f "${SRC_DIR}/${APP}d.sh" ]] || die "Fehlt: ${SRC_DIR}/${APP}d.sh"
  [[ -f "${PKG_DIR}/${APP}.service" ]] || die "Fehlt: ${PKG_DIR}/${APP}.service"
  [[ -f "${PKG_DIR}/logrotate.${APP}" ]] || die "Fehlt: ${PKG_DIR}/logrotate.${APP}"
  [[ -f "${SRC_DIR}/config.example.conf" ]] || die "Fehlt: ${SRC_DIR}/config.example.conf"
}

# ----------------------------
# Debian deps
# ----------------------------
install_deps_debian() {
  export DEBIAN_FRONTEND=noninteractive

  if ! have_cmd apt-get; then
    die "apt-get nicht gefunden. Dieses install.sh unterstützt aktuell Debian/Ubuntu."
  fi

  info "APT update…"
  apt-get update -y

  # Heal a broken dpkg state if previous attempts failed
  info "DPKG state check/heal…"
  apt-get -y -f install

  # Speedtest handling:
  # - Prefer Ookla package 'speedtest' (packagecloud) if available
  # - Avoid installing 'speedtest-cli' because it collides on /usr/bin/speedtest
  # - If speedtest-cli is installed, remove it (safe) to avoid conflicts.
  if dpkg -s speedtest-cli >/dev/null 2>&1; then
    info "Entferne speedtest-cli (Konflikt mit Ookla speedtest)…"
    apt-get purge -y speedtest-cli || true
    apt-get -y -f install
  fi

  local pkgs=(
    iputils-ping
    dnsutils
    mtr-tiny
    jq
    gawk
    coreutils
    iperf3
  )

  # Install Ookla speedtest if not already present
  if ! dpkg -s speedtest >/dev/null 2>&1; then
    pkgs+=(speedtest)
  fi

  info "Installiere Abhängigkeiten: ${pkgs[*]}"
  apt-get install -y "${pkgs[@]}"

  # Final heal just in case
  apt-get -y -f install
}

# ----------------------------
# Files
# ----------------------------
install_files() {
  info "Installiere Dateien nach ${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"

  # Prefer rsync, fallback to cp -a
  if have_cmd rsync; then
    rsync -a "${SRC_DIR}/" "${INSTALL_DIR}/"
    # Install installer itself for uninstall/upgrade
cp "$(basename "$0")" "${INSTALL_DIR}/install.sh"
chmod 0755 "${INSTALL_DIR}/install.sh"

  else
    cp -a "${SRC_DIR}/." "${INSTALL_DIR}/"
    # Install installer itself for uninstall/upgrade
cp "$(basename "$0")" "${INSTALL_DIR}/install.sh"
chmod 0755 "${INSTALL_DIR}/install.sh"

  fi

  # Ensure executable scripts
  find "${INSTALL_DIR}" -type f -name "*.sh" -exec chmod 0755 {} \;

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

usage() {
  cat <<USAGE
Usage:
  netwatch start|stop|restart|status
  netwatch enable|disable
  netwatch logs          (journalctl -u netwatch -f)
  netwatch logs-tail N   (journalctl -u netwatch -n N)
  netwatch export        (list evidence bundles)
  netwatch report        (show latest human report if present)
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
  export)
    ls -lah /var/log/netwatch/export 2>/dev/null || true
    ;;
  report)
    latest="$(ls -1t /var/log/netwatch/export/*/REPORT.md 2>/dev/null | head -n 1 || true)"
    if [[ -n "${latest}" ]]; then
      echo "==> ${latest}"
      sed -n '1,200p' "${latest}"
    else
      echo "Kein REPORT.md gefunden (noch keine Export-Läufe?)"
    fi
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

# ----------------------------
# Config & dirs
# ----------------------------
install_config() {
  info "Konfiguration…"
  mkdir -p "${CONF_DIR}"

  # Always ensure example config is available in INSTALL_DIR
  if [[ ! -f "${INSTALL_DIR}/config.example.conf" ]]; then
    # Should have been copied by install_files, but be safe
    cp "${SRC_DIR}/config.example.conf" "${INSTALL_DIR}/config.example.conf"
  fi

  if [[ ! -f "${CONF_FILE}" ]]; then
    info "Erzeuge Default-Config: ${CONF_FILE}"
    cp "${INSTALL_DIR}/config.example.conf" "${CONF_FILE}"
  else
    info "Config existiert bereits, lasse unverändert: ${CONF_FILE}"
  fi

  # Create log dirs so service cannot fail on missing paths
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

  # Enable + start (or restart if already active)
  systemctl enable "${APP}.service"
  systemctl restart "${APP}.service" || systemctl start "${APP}.service"
}

# ----------------------------
# Uninstall
# ----------------------------
uninstall_all() {
  local purge="${1:-false}"

  have_cmd systemctl && systemctl disable --now "${APP}.service" 2>/dev/null || true
  rm -f "${SYSTEMD_UNIT}"
  have_cmd systemctl && systemctl daemon-reload 2>/dev/null || true

  rm -f "${CTL}" "${RUNNER}" "${LOGROTATE_DST}"
  rm -rf "${INSTALL_DIR}"

  if [[ "${purge}" == "true" ]]; then
    info "Purge: entferne Config + Logs"
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
    --uninstall)
      uninstall_all false
      exit 0
      ;;
    --purge)
      uninstall_all true
      exit 0
      ;;
    "" )
      ;;
    * )
      usage
      exit 2
      ;;
  esac

  require_files
  install_deps_debian
  install_files
  install_config
  install_logrotate
  install_systemd

  echo "✅ ${APP} installiert."
  echo "Config: ${CONF_FILE}"
  echo "Status: ${APP} status"
  echo "Logs: ${APP} logs"
  echo "Evidence: ${APP} export"
}

main "$@"
