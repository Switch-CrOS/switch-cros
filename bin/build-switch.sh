#!/usr/bin/env bash
# Build switch-t210 packages.  Run OUTSIDE the SDK (on the host).
#
# Strategy: binpkgs for the whole tree (fast), then force-rebuild ONLY the
# packages that compile in brillo::SecureBlob / SecureAllocator from source,
# so they pick up the switch-t210 libbrillo patch (graceful MADV_WIPEONFORK
# degradation on the L4T 4.9 kernel).  secure_allocator.h is a header-only
# template, so each consumer bakes in its own copy; Google's prebuilt binpkgs
# of those consumers carry the UNPATCHED header and abort on 4.9.  build-packages
# already rebuilds libbrillo itself (locally modified) but not its consumers.
#
# The consumer list is DERIVED from platform2 each run, so it stays correct as
# upstream adds/removes SecureBlob users — nothing to hand-maintain.
#
# (Long term, at "official" scale: run this once on a build server and publish
# the resulting binpkgs to a Switchroot binhost, set via PORTAGE_BINHOST in the
# overlay's make.conf; then everyone else runs plain build-packages.)
set -euo pipefail

CROS=${CROS:-$HOME/chromiumos}
BOARD=${BOARD:-switch-t210}
P2="$CROS/src/platform2"
OV="$CROS/src/third_party/chromiumos-overlay"

# Map a platform2 source dir to its chromeos-base package atom.  Almost all are
# 1:1 (chromeos-base/<dir>); list the few exceptions here.  Dirs that don't
# resolve to an existing ebuild are skipped (e.g. arc/vm_tools — not shipped).
dir_to_atom() {
  case "$1" in
    init) echo "chromeos-base/chromeos-init" ;;
    *)    echo "chromeos-base/$1" ;;
  esac
}

echo "==> deriving brillo::SecureBlob / SecureAllocator consumers from platform2"
mapfile -t consumers < <(
  grep -rlE 'brillo/secure_(blob|allocator|vector|string)\.h|brillo::Secure(Blob|Vector|Allocator|String)' \
    --include='*.cc' --include='*.h' "$P2" 2>/dev/null \
  | sed "s#^${P2}/##; s#/.*##" | sort -u \
  | while read -r d; do
      atom=$(dir_to_atom "$d"); pkg=${atom#chromeos-base/}
      ls "$OV"/chromeos-base/"$pkg"/"$pkg"-*.ebuild >/dev/null 2>&1 && echo "$atom"
    done
)
if [[ ${#consumers[@]} -eq 0 ]]; then
  echo "!! no SecureBlob consumers derived — aborting (would ship unpatched)" >&2
  exit 1
fi
printf '    %s\n' "${consumers[@]}"

cd "$CROS"

echo "==> cros build-packages (binpkgs)"
cros build-packages --board="$BOARD" "$@"

# Keep only consumers actually installed in the board image.  The derivation
# greps all of platform2, but many SecureBlob users aren't part of this board
# (e.g. minios needs USE=minios; farfetchd/odml/etc. aren't shipped).  There's
# nothing to rebuild for a package that isn't installed, and emerging one that
# can't satisfy REQUIRED_USE aborts the whole run.
echo "==> filtering to consumers installed in the board"
declare -A installed=()
while read -r p; do installed[$p]=1; done < <(
  cros_sdk -- bash -c "ls /build/$BOARD/var/db/pkg/chromeos-base/ 2>/dev/null" \
    | sed -E 's/-[0-9].*$//' | sort -u
)
keep=()
for atom in "${consumers[@]}"; do
  [[ -n "${installed[${atom#chromeos-base/}]:-}" ]] && keep+=("$atom")
done
consumers=("${keep[@]}")
if [[ ${#consumers[@]} -eq 0 ]]; then
  echo "!! no installed SecureBlob consumers — aborting (would ship unpatched)" >&2
  exit 1
fi
printf '    %s\n' "${consumers[@]}"

echo "==> force-rebuilding consumers from source (against patched libbrillo)"
cros_sdk -- "emerge-${BOARD}" --usepkg=n --jobs="$(nproc)" \
  --reinstall-atoms="${consumers[*]}" "${consumers[@]}"

echo "==> packages built"
