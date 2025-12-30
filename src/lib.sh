#!/usr/bin/env bash
set -euo pipefail

ts_iso() { date -Is; }
ts_epoch() { date +%s; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

mkdirp() { mkdir -p "$1"; }

log_jsonl() {
  local file="$1" json="$2"
  printf '%s %s\n' "$(ts_iso)" "$json" >> "$file"
}

die() { echo "ERROR: $*" >&2; exit 1; }
