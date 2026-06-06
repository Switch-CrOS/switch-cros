#!/usr/bin/env bash
# One-shot "track upstream + rebuild" for the Switch ChromiumOS port.
#
#   1. repo sync                  (advance the tree to current upstream)
#   2. re-fork chromeos-chrome    (re-apply our edits to the new chrome ebuild)
#   3. build-packages / build-image inside the SDK
#   4. install the Switch bootstack onto the image
#
# Designed to be cron-safe: logs to a file, exits non-zero on any failure so
# the cron wrapper (or you) get notified, and never silently ships a broken
# image.  The kernel is intentionally NOT rebuilt here — it changes rarely and
# lives in a separate flow (l4t-kernel-build-scripts); rebuild it by hand when
# the L4T sources actually move.
set -euo pipefail

CROS=${CROS:-$HOME/chromiumos}
BOARD=${BOARD:-switch-t210}
SWITCH_CROS=${SWITCH_CROS:-$HOME/switch-cros}
LOG=${LOG:-$SWITCH_CROS/logs/update-$(date +%Y%m%d-%H%M%S).log}
mkdir -p "$(dirname "$LOG")"

# Everything to the log AND the console.
exec > >(tee -a "$LOG") 2>&1
echo "=== switch-cros-update $(date -u) board=$BOARD ==="

cd "$CROS"

echo "--- [1/4] repo sync ---"
# NB: this only works cleanly if your overlay is its own git project (added via
# .repo/local_manifests/), not uncommitted edits inside board-overlays.  See
# the publishing notes.  repo sync will refuse to clobber dirty trees.
# XXX: allow it to fail anyways
repo sync -j"$(nproc)" -q || true

echo "--- [2/4] re-fork chromeos-chrome to current upstream ---"
"$SWITCH_CROS/bin/refork-chromeos-chrome.sh"

echo "--- [3/4] build (binpkgs + source-rebuild of SecureBlob consumers) ---"
ov_chrome=$(ls "$CROS"/src/overlays/overlay-switch-t210/chromeos-base/chromeos-chrome/chromeos-chrome-*.ebuild | grep -v -- -9999 | sort -V | tail -1)
ov_chrome_sdk="/mnt/host/source/${ov_chrome#"$CROS"/}"
# Regenerate the forked chrome ebuild's Manifest (reach into the SDK for the
# one command that needs it).
cros_sdk -- bash -euc "ebuild '$ov_chrome_sdk' manifest"
# build-packages (binpkgs) + force-rebuild the brillo::SecureBlob consumers
# from source.  build-switch.sh runs on the host and reaches into the SDK
# itself via cros_sdk --.
BOARD="$BOARD" CROS="$CROS" "$SWITCH_CROS/bin/build-switch.sh"
cros build-image --board=$BOARD --no-enable-rootfs-verification test

echo "--- [4/4] install Switch bootstack ---"
img=$(ls -t "$CROS"/src/build/images/"$BOARD"/latest/*.bin 2>/dev/null | head -1)
[[ -n "$img" ]] || { echo "no image produced" >&2; exit 1; }
"$SWITCH_CROS/bin/install-switch-bootstack-to-image.sh" "$img"

echo "=== done $(date -u): $img ==="
