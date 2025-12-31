#!/usr/bin/env bash
set -euo pipefail

# Always parse numbers using dot decimal (C locale)
export LC_ALL=C

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ts_iso() { date -Is; }
ts_epoch() { date +%s; }

mkdirp() { mkdir -p "$1"; }

json_escape() {
  # minimal JSON escape for strings
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e $'s/\t/\\t/g' -e $'s/\r/\\r/g' -e $'s/\n/\\n/g'
}

log_jsonl() {
  local file="$1"; shift
  local line="$1"
  mkdir -p "$(dirname "$file")"
  printf "%s\n" "$line" >> "$file"
}

csv_append() {
  local file="$1"; shift
  mkdir -p "$(dirname "$file")"
  printf "%s\n" "$*" >> "$file"
}

# safe float formatting using awk (avoids bash printf float locale issues)
fmt2() {
  awk -v x="${1:-0}" 'BEGIN{ if(x==""){print ""} else {printf "%.2f", x} }'
}

# percentile helper (p between 0 and 100) for a single-column list of numbers (stdin)
percentile() {
  local p="${1:?p}"
  awk -v p="$p" '
  {a[n++]=$1}
  END{
    if(n==0){print ""; exit 0}
    asort(a)
    idx = int((p/100)*(n-1))+1
    if(idx<1) idx=1
    if(idx>n) idx=n
    print a[idx]
  }'
}

# median of numbers (stdin)
median() { percentile 50; }
