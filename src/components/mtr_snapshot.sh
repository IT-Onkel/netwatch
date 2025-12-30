#!/usr/bin/env bash
set -euo pipefail
# Produces: mtr snapshots in LOG_DIR/mtr/
. "$(dirname "$0")/../lib.sh"

main() {
  local log_dir="${1:-}"
  local target="${2:-}"
  [[ -n "$log_dir" && -n "$target" ]] || die "usage: mtr_snapshot.sh LOG_DIR TARGET"

  mkdirp "${log_dir}/mtr"
  local ts out
  ts="$(date +%Y%m%d-%H%M%S)"
  out="${log_dir}/mtr/${ts}_${target}.txt"

  ( mtr -ezbw -c 200 "$target" || true ) > "$out" 2>&1
}

main "$@"
