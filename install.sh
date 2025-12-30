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

require_files() {
  [[ -d "${SRC_DIR}" ]] || { echo "Fehlt: ${SRC_DIR}/"; exit 1; }
  [[ -f "${SRC_DIR}/${APP}d.sh" ]] || { echo "Fehlt: ${SRC_DIR}/${APP}d.sh"; exit 1; }
  [[ -f "${PKG_DIR}/${APP}.service" ]] || { echo "Fehlt: ${PKG_DIR}/${APP}.service"; exit 1; }
  [[ -f "${PKG_DIR}/logrotate.${APP}" ]] || { echo "Fehlt: ${PKG_DIR}/logrotate.${APP}"; exit 1; }
}

install_deps_debian() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y || true
  apt-get install -y \
    iputils-ping dnsutils mtr-tiny jq gawk coreutils iperf3 speedtest-cli \
    || true
  # Optional: Ookla speedtest might exist separately; script uses it if present.
}

install_files() {
  mkdir -p "${INSTALL_DIR}"
  rsync -a "${SRC_DIR}/" "${INSTALL_DIR}/"
  find "${INSTALL_DIR}" -type f -name "*.sh" -exec chmod 0755 {} \;

  cat > "${RUNNER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${INSTALL_DIR}/${APP}d.sh"
EOF
  chmod 0755 "${RUNNER}"

  cat > "${CTL}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
svc="netwatch.service"

usage() {
  cat <<USAGE
Usage:
  netwatch start|stop|restart|status
  netwatch enable|disable
  netwatch logs        (journalctl -u netwatch -f)
  netwatch export      (lists evidence bundles)
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
  export)
    ls -lah /var/log/netwatch/export 2>/dev/null || true
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
  mkdir -p "${CONF_DIR}"

  # Quelle der Example-Config: erst aus installierten Files, fallback aus Repo
  local example_src=""
  if [[ -f "${INSTALL_DIR}/config.example.conf" ]]; then
    example_src="${INSTALL_DIR}/config.example.conf"
  elif [[ -f "${SRC_DIR}/config.example.conf" ]]; then
    example_src="${SRC_DIR}/config.example.conf"
  else
    echo "Fehlt: config.example.conf (weder in ${INSTALL_DIR} noch in ${SRC_DIR})"
    exit 1
  fi

  if [[ ! -f "${CONF_FILE}" ]]; then
    cp "$example_src" "${CONF_FILE}"
  fi

  # Log dirs anlegen (damit Service nicht wegen fehlender Pfade scheitert)
  mkdir -p /var/log/netwatch /var/log/netwatch/export
}


install_logrotate() {
  install -m 0644 "${PKG_DIR}/logrotate.${APP}" "${LOGROTATE_DST}"
}

install_systemd() {
  sed "s|@@RUNNER@@|${RUNNER}|g" "${PKG_DIR}/${APP}.service" > "${SYSTEMD_UNIT}"
  systemctl daemon-reload
  systemctl enable --now "${APP}.service"
}

uninstall_all() {
  systemctl disable --now "${APP}.service" 2>/dev/null || true
  rm -f "${SYSTEMD_UNIT}"
  systemctl daemon-reload || true
  rm -f "${CTL}" "${RUNNER}" "${LOGROTATE_DST}"
  rm -rf "${INSTALL_DIR}"
  echo "Uninstall fertig. Config/Logs bleiben:"
  echo "  ${CONF_FILE}"
  echo "  /var/log/netwatch/"
}

main() {
  need_root
  if [[ "${1:-}" == "--uninstall" ]]; then
    uninstall_all; exit 0
  fi

  require_files
  install_deps_debian
  install_files
  install_config
  install_logrotate
  install_systemd

  echo "✅ netwatch installiert."
  echo "Config: ${CONF_FILE}"
  echo "Status: netwatch status"
  echo "Evidence: netwatch export"
}

main "$@"
