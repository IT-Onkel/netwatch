#!/usr/bin/env bash
set -euo pipefail

OWNER="IT-Onkel"
REPO="netwatch"

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
    echo "Weder curl noch wget vorhanden."; exit 1
  fi
}

main() {
  need_root

  local tmp
  tmp="$(mktemp -d)"
  trap '[ -n "${tmp:-}" ] && rm -rf "$tmp"' EXIT


  local tar_url
  if [[ "$PINNED_TAG" == "latest" ]]; then
    tar_url="https://github.com/${OWNER}/${REPO}/releases/latest/download/${REPO}.tar.gz"
  else
    tar_url="https://github.com/${OWNER}/${REPO}/releases/download/${PINNED_TAG}/${REPO}.tar.gz"
  fi

  echo "netwatch bootstrap: fetching ${tar_url}"
  fetch "$tar_url" "${tmp}/${REPO}.tar.gz"

  cd "$tmp"
  tar -xzf "${REPO}.tar.gz"

  # Find project root (contains install.sh + src/)
  local proj
  proj="$(find . -maxdepth 2 -type f -name install.sh | head -n 1 | xargs dirname)"

  [[ -d "${proj}/src" ]] || { echo "src/ not found in release archive"; exit 1; }

  echo "netwatch bootstrap: running installer in ${proj}"
  cd "$proj"
  bash ./install.sh
}

main
