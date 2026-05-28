#!/usr/bin/env bash
set -euo pipefail

core=${1:?usage: analyze-switch-chrome-core.sh CORE}
root=${CHROMIUMOS_ROOT:-$HOME/chromiumos}
work_host="$root/src/switch-crash-analyze"
work_chroot=/mnt/host/source/src/switch-crash-analyze
img="$root/src/build/images/switch-t210/latest/chromiumos_test_image.bin"
chrome_pkg="$root/out/build/switch-t210/packages/chromeos-base/chromeos-chrome-150.0.7850.0_pre1634046_rc-r2.tbz2"

mkdir -p "$work_host"
cp -f "$core" "$work_host/input.core"

if [[ ! -f "$work_host/chrome.real" ]]; then
  mnt=$(mktemp -d)
  loop=$(sudo losetup --find --partscan --show "$img")
  cleanup() {
    set +e
    sudo umount "$mnt" 2>/dev/null
    sudo losetup -d "$loop" 2>/dev/null
    rmdir "$mnt" 2>/dev/null
  }
  trap cleanup EXIT
  sudo mount "${loop}p3" "$mnt"
  sudo cp -f "$mnt/opt/google/chrome/chrome.real" "$work_host/chrome.real"
  sudo chmod 0644 "$work_host/chrome.real"
  cleanup
  trap - EXIT
fi

debug_chrome="$work_host/pkg-extract/usr/lib/debug/opt/google/chrome/chrome.debug"
if [[ ! -f "$debug_chrome" && -f "$chrome_pkg" ]]; then
  mkdir -p "$work_host/pkg-extract"
  tar -xf "$chrome_pkg" -C "$work_host/pkg-extract" \
    ./usr/lib/debug/opt/google/chrome/chrome.debug \
    ./usr/lib/debug/.build-id/5b/ca5ecd983aed0fdb1fc033dad6c657fec7d689.debug \
    2>"$work_host/pkg-extract.err" || true
fi
gdb_exe=./chrome.real
if [[ -f "$debug_chrome" ]]; then
  gdb_exe=./pkg-extract/usr/lib/debug/opt/google/chrome/chrome.debug
fi

cat >"$work_host/gdb.cmds" <<'GDB'
set pagination off
set confirm off
set print thread-events off
set sysroot /build/switch-t210
set solib-search-path /build/switch-t210/lib64:/build/switch-t210/usr/lib64:/build/switch-t210/opt/google/chrome
set debug-file-directory /mnt/host/source/src/switch-crash-analyze/pkg-extract/usr/lib/debug:/build/switch-t210/usr/lib/debug
info files
info sharedlibrary
info threads
thread 1
bt 40
info registers
x/32i $pc-64
thread apply all bt 40
thread apply all info registers
quit
GDB

"$root/chromite/bin/cros_sdk" -- bash -lc \
  "cd '$work_chroot' && aarch64-cros-linux-gnu-gdb --batch -x gdb.cmds '$gdb_exe' ./input.core" \
  >"$work_host/gdb-core.txt" 2>&1 || true

echo "Wrote $work_host/gdb-core.txt"
echo "--- top symbolized stack ---"
grep -E '^#(0|1|2|3|4|5|6|7|8|9|10) ' "$work_host/gdb-core.txt" | head -40 || true
echo "--- signal / core summary ---"
grep -Ei 'core was generated|program terminated|signal|sigtrap|thread|lwp|pc |#0|chrome|break|trap|check|fatal' \
  "$work_host/gdb-core.txt" | head -220 || true
echo "--- first backtraces ---"
awk '
  /^Thread [0-9]+/ || /^#0/ {printing=1}
  printing {print; count++}
  count >= 180 {exit}
' "$work_host/gdb-core.txt"
