#!/usr/bin/env bash
set -euo pipefail

OWNER="IT-Onkel"
REPO="netwatch"

# Optional: pin a version (tag), e.g.:
# curl .../netwatch-install.sh | sudo bash -s -- v1.2.3
PINNED_TAG="${1:-latest}"

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Bitte mit sudo ausführen."; exit 1; }
}

have() { command -v "$1" >/dev/null 2>&1; }

fetch() {
  local url="$1" out="$2"
  if have curl; then
    curl -fsSL "$url" -o "$out"
  elif have wget; then
    wget -q "$url" -O "$out"
  else
    echo "Weder curl noch wget vorhanden. Bitte eins installieren (apt-get install -y curl)."
    exit 1
  fi
}

main() {
  need_root

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  local tar_url
  if [[ "$PINNED_TAG" == "latest" ]]; then
    tar_url="https://github.com/${OWNER}/${REPO}/releases/latest/download/${REPO}.tar.gz"
  else
    tar_url="https://github.com/${OWNER}/${REPO}/releases/download/${PINNED_TAG}/${REPO}.tar.gz"
  fi

  echo "netwatch bootstrap: fetching ${tar_url}"
  fetch "$tar_url" "${tmp}/${REPO}.tar.gz"

  mkdir -p "${tmp}/${REPO}"
  tar -xzf "${tmp}/${REPO}.tar.gz" -C "${tmp}/${REPO}"

  local install_path=""
  if [[ -f "${tmp}/${REPO}/install.sh" ]]; then
    install_path="${tmp}/${REPO}/install.sh"
  else
    install_path="$(find "${tmp}/${REPO}" -maxdepth 2 -type f -name install.sh | head -n 1 || true)"
  fi

  [[ -n "$install_path" && -f "$install_path" ]] || { echo "install.sh nicht im Release-Tarball gefunden."; exit 1; }

  echo "netwatch bootstrap: running ${install_path}"
  bash "$install_path"
}

main
