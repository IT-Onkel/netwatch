#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/../lib.sh"

usage() { die "usage: mtr_snapshot.sh run LOG_DIR TARGET"; }

cmd="${1:-}"; shift || true
[[ "$cmd" == "run" ]] || usage

LOG_DIR="${1:-}"; TARGET="${2:-}"
[[ -n "$LOG_DIR" && -n "$TARGET" ]] || usage

mkdirp "${LOG_DIR}/mtr"
ts="$(date +%Y%m%dT%H%M%S)"
out="${LOG_DIR}/mtr/mtr_${TARGET//[:\/]/_}_${ts}.txt"

if have_cmd mtr; then
  mtr -n -r -c 10 "$TARGET" >"$out" 2>&1 || true
else
  echo "mtr not found" >"$out"
fi
