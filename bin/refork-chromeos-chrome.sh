#!/usr/bin/env bash
# Re-fork chromeos-chrome into the switch-t210 overlay, tracking whatever
# version upstream chromiumos-overlay currently ships.
#
# We don't carry a static copy of the (frequently-uprevved) chrome ebuild;
# instead we keep our edits as a patch and regenerate the fork from the
# current upstream ebuild.  This turns a milestone/canary bump into a no-op
# (patch still applies) instead of a manual re-port.
#
# Fails loudly if the patch no longer applies (upstream restructured the
# ebuild) — that's the rare case that genuinely needs a human.
set -euo pipefail

CROS=${CROS:-$HOME/chromiumos}
UP_DIR="$CROS/src/third_party/chromiumos-overlay/chromeos-base/chromeos-chrome"
OV_DIR="$CROS/src/overlays/overlay-switch-t210/chromeos-base/chromeos-chrome"
PATCH="$OV_DIR/files/switch-chromeos-chrome-ebuild.patch"

[[ -f "$PATCH" ]] || { echo "missing edits patch: $PATCH" >&2; exit 1; }

# Latest non-9999 upstream ebuild.
up=$(ls "$UP_DIR"/chromeos-chrome-*.ebuild 2>/dev/null | grep -v -- -9999 | sort -V | tail -1)
[[ -n "$up" ]] || { echo "no upstream chromeos-chrome ebuild found" >&2; exit 1; }
upbase=$(basename "$up" .ebuild)

# Split PV and revision so the overlay can win the version tie (overlay rev =
# upstream rev + 1).
if [[ "$upbase" =~ ^chromeos-chrome-(.+)-r([0-9]+)$ ]]; then
  pv="${BASH_REMATCH[1]}"; uprev="${BASH_REMATCH[2]}"
else
  pv="${upbase#chromeos-chrome-}"; uprev=0
fi
ovrev=$((uprev + 1))
newname="chromeos-chrome-${pv}-r${ovrev}.ebuild"

if [[ -f "$OV_DIR/$newname" ]]; then
  echo "chrome fork already current: ${pv}-r${ovrev}"
  exit 0
fi

echo "Re-forking chromeos-chrome: upstream ${pv}-r${uprev} -> overlay ${pv}-r${ovrev}"
rm -f "$OV_DIR"/chromeos-chrome-*.ebuild
cp "$up" "$OV_DIR/$newname"

if ! patch "$OV_DIR/$newname" < "$PATCH"; then
  echo "ERROR: switch-chromeos-chrome-ebuild.patch did not apply to ${pv}." >&2
  echo "Upstream restructured the chrome ebuild; rebase the patch:" >&2
  echo "  diff -u $up <your-edited-copy> (drop the GIT_COMMIT hunk) > $PATCH" >&2
  rm -f "$OV_DIR/$newname"
  exit 1
fi

# Chrome's SRC_URI is empty (CHROME_ORIGIN-driven), so the Manifest is trivial;
# mirror upstream's if it exists.
[[ -f "$UP_DIR/Manifest" ]] && cp "$UP_DIR/Manifest" "$OV_DIR/Manifest"

echo "OK: $newname"
echo "NB: the chrome SOURCE patches (PATCHES=) must still apply to Chrome ${pv};"
echo "    if emerge fails in src_prepare, rebase files/switch-*.patch."
