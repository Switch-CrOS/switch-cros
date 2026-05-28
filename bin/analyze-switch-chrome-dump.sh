#!/usr/bin/env bash
set -euo pipefail

dump=${1:?usage: analyze-switch-chrome-dump.sh MINIDUMP}
root=${CHROMIUMOS_ROOT:-$HOME/chromiumos}
out_dir=${OUT_DIR:-/tmp/switch-crash-analyze}
mkdir -p "$out_dir"

tools_ld="$root/chroot/usr/lib64:$root/chroot/lib64"
stackwalk="$root/chroot/usr/bin/minidump_stackwalk"

if [[ ! -x "$stackwalk" ]]; then
  echo "minidump_stackwalk not found at $stackwalk" >&2
  exit 1
fi

base=$(basename "$dump")
raw="$out_dir/${base}.stackwalk.txt"

LD_LIBRARY_PATH="$tools_ld" "$stackwalk" "$dump" >"$raw" 2>&1 || true

echo "Wrote $raw"
echo "--- crash header ---"
sed -n '1,80p' "$raw"
echo "--- crashing thread excerpt ---"
awk '
  /^Thread [0-9]+ \\(crashed\\)/ {printing=1; count=0}
  printing {print; count++}
  printing && count >= 80 {exit}
' "$raw"
echo "--- module offsets mentioning chrome ---"
grep -Ei 'chrome|libc|break|trap|signal|assert|check' "$raw" | head -160 || true
