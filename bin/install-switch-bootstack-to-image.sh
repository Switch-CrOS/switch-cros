#!/usr/bin/env bash
# Image-level post-build steps for switch-t210.
#
# Everything that *can* live in the overlay (BSP ebuild, platform2 patches,
# upstart .override files, board_specific_setup.sh) has been moved there.
# This script is intentionally limited to operations that need a built image
# on disk to mutate — partition table surgery, Hekate-shaped FAT repack, and
# a handful of image-time fixups that haven't been pushed into the overlay
# yet (see TODOs).
set -euo pipefail

image=${1:?usage: install-switch-bootstack-to-image.sh IMAGE}
boot_part_num=${BOOT_PART_NUM:-auto}
root_part_num=${ROOT_PART_NUM:-3}
os_dir=${SWITCHROOT_OS_DIR:-chromiumos}
boot_fat_bits=${BOOT_FAT_BITS:-16}

if [[ ! -f "$image" ]]; then
  echo "image not found: $image" >&2
  exit 1
fi

boot_mnt=$(mktemp -d)
root_mnt=$(mktemp -d)
state_mnt=$(mktemp -d)
loop=""
cleanup() {
  set +e
  if mountpoint -q "$boot_mnt"; then sudo umount "$boot_mnt"; fi
  if mountpoint -q "$root_mnt"; then sudo umount "$root_mnt"; fi
  if mountpoint -q "$state_mnt"; then sudo umount "$state_mnt"; fi
  if [[ -n "$loop" ]]; then sudo losetup -d "$loop"; fi
  rmdir "$boot_mnt" "$root_mnt" "$state_mnt" 2>/dev/null || true
}
trap cleanup EXIT

loop=$(sudo losetup --find --partscan --show "$image")
root_part="${loop}p${root_part_num}"
[[ -b "$root_part" ]] || root_part="${loop}${root_part_num}"
if [[ ! -b "$root_part" ]]; then
  echo "root partition ${root_part_num} not found on $loop" >&2
  exit 1
fi
sudo mount "$root_part" "$root_mnt"

# Strip kernel leftovers from upstream chromeos-bsp/sys-kernel that we don't
# use — we ship our own L4T 4.9 kernel + modules via the BSP ebuild.
# TODO: move into board_specific_setup.sh so this happens at build_image
# time and the leftovers never reach the image.
sudo rm -rf \
  "$root_mnt/lib/modules/5.15."* \
  "$root_mnt/usr/src/linux" \
  "$root_mnt/boot/vmlinux"* \
  "$root_mnt/boot/System.map"* \
  2>/dev/null || true

# Hekate requires partition #1 to be FAT.  After the physical repack below,
# ChromiumOS stateful lives at p12 (not its usual p1).  Rewrite the
# chromeos-installer's partition_vars.json to match the post-repack layout.
# TODO: drive this from overlay's scripts/disk_layout.json so the right
# values are baked in by build_image and this patch becomes unnecessary.
partition_vars="$root_mnt/usr/sbin/partition_vars.json"
if [[ -f "$partition_vars" ]]; then
  sudo python3 - "$partition_vars" <<'PARTVARS'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
for section in ("load_base_vars", "load_partition_vars"):
    values = data.get(section)
    if not isinstance(values, dict):
        continue
    values.update({
        "PARTITION_NUM_STATE": "12",
        "FS_FORMAT_STATE": "ext4",
        "FS_OPTIONS_STATE": "",
        "PARTITION_SIZE_STATE": "8589990400",
        "DATA_SIZE_STATE": "8589990400",
        "PARTITION_NUM_12": "12",
        "FS_FORMAT_12": "ext4",
        "FS_OPTIONS_12": "",
        "PARTITION_SIZE_12": "8589990400",
        "DATA_SIZE_12": "8589990400",
        "PARTITION_NUM_EFI_SYSTEM": "1",
        "FS_FORMAT_EFI_SYSTEM": "vfat",
        "FS_OPTIONS_EFI_SYSTEM": "",
        "PARTITION_SIZE_EFI_SYSTEM": "134217728",
        "DATA_SIZE_EFI_SYSTEM": "134217728",
        "PARTITION_NUM_1": "1",
        "FS_FORMAT_1": "vfat",
        "FS_OPTIONS_1": "",
        "PARTITION_SIZE_1": "134217728",
        "DATA_SIZE_1": "134217728",
    })
path.write_text(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n")
PARTVARS
  sudo chmod 0644 "$partition_vars"
fi

# build_image ships rootfs with `/` owned by chronos:chronos, which trips
# systemd-tmpfiles "unsafe path transition" on every canonicalization
# through /, blocking creation of /run/chromeos_startup, /run/namespaces,
# /var/log/chrome, /var/log/ui, etc.
# TODO: move into board_specific_setup.sh.
sudo chown root:root "$root_mnt"

# --- Platform2 hacks pending real patches in the overlay ---
# Each of these mutations should become a .patch under
# src/overlays/overlay-switch-t210/chromeos-base/chromeos-init/files/ once
# someone bothers to wire up the chromeos-init overlay ebuild.

# startup.conf: drop encrypted_stateful — no TPM on Switch.
# Replace bare `--encrypted_stateful` at end-of-line with `=false`; the
# regex won't match if it's already `=false`, keeping it idempotent.
startup_conf="$root_mnt/etc/init/startup.conf"
if [[ -f "$startup_conf" ]]; then
  sudo sed -i -E 's|--encrypted_stateful$|--encrypted_stateful=false|' \
    "$startup_conf"
fi

# udev-trigger-early.conf: drop --settle. udev 249 writes "add <UUID>" to
# sysfs uevent files; Linux 4.9 kobject_action_type rejects UUIDs and never
# fires the event, so --settle blocks forever and starves the boot chain.
if [[ -f "$root_mnt/etc/init/udev-trigger-early.conf" ]]; then
  sudo sed -i -E 's/[[:space:]]--settle\b//g' \
    "$root_mnt/etc/init/udev-trigger-early.conf"
fi

# ui.conf / tpm_managerd.conf: drop tmpfiles stanza (pulls in Debian
# tmpfiles fragments we don't fully sanitize yet, hangs upstart pre-start).
for job in ui tpm_managerd; do
  conf="$root_mnt/etc/init/${job}.conf"
  [[ -f "$conf" ]] || continue
  sudo sed -i -E 's|^(tmpfiles )|# switch-t210 disabled: \1|' "$conf"
done

# --- chrome_dev.conf append (idempotent via sentinel) ---
# Once we have an overlay patch on chromeos-base/chromeos-login's
# chrome_dev.conf (or a Switch-specific chrome_dev.d/ fragment dir), this
# whole block goes away.
chrome_dev="$root_mnt/etc/chrome_dev.conf"
sentinel="# switch-t210 bring-up: Xorg"
if [[ -f "$chrome_dev" ]] && ! sudo grep -q "$sentinel" "$chrome_dev"; then
  sudo tee -a "$chrome_dev" >/dev/null <<EOF

$sentinel
DISPLAY=:0
!--ozone-platform
!--use-gl
!--disable-software-rasterizer
!--disable-gpu
!--disable-gpu-compositing
!--disable-gpu-rasterization
--ozone-platform=x11
--ash-host-window-bounds=1280x720
--disable-features=FederatedService,EncryptedReportingPipeline,DeviceEncryptedReportingPipelineEnabled,CrOSLateBootMissiveStorage,CloudReporting,EnterpriseReportingUI,EnableReportingFromUnmanagedDevices,ReportingServiceAlwaysFlush,ReportingAndNEL,FledgeRealTimeReporting,Floss,FlossAvailabilityCheck,UseFlossInsteadOfBluez,FlossTelephony
--use-gl=angle
--use-angle=gles
# Force GPU (tile) rasterization on. The CrOS GPU blocklist (entry 137 in
# software_rendering_list.json) disables gpu_tile_rasterization for any GPU not
# in its allowlist (Intel/Mali-T8|G/Imagination/Freedreno/AMD); Tegra isn't
# listed, so it defaults to software raster. This switch is honored before the
# blocklist check in GetGpuRasterizationFeatureStatus(). ~7% on Speedometer 3.1.
--enable-gpu-rasterization
EOF
  sudo chmod 0644 "$chrome_dev"
fi

# fwupd: disable the test/dummy plugins.  On dev/test images they expose a
# phantom "Integrated Webcam" firmware update that can never apply (the Switch
# has no webcam).  fwupd.conf is owned by the fwupd package, so we can't ship
# it from the overlay without a file collision; append to the existing
# DisabledPlugins line here instead.  Idempotent.
fwupd_conf="$root_mnt/etc/fwupd/fwupd.conf"
if [[ -f "$fwupd_conf" ]] && ! sudo grep -qE '^DisabledPlugins=.*\btest\b' "$fwupd_conf"; then
  sudo sed -i -E 's|^(DisabledPlugins=.*)$|\1;test;test_ble|' "$fwupd_conf"
fi

sync
sudo umount "$root_mnt"
sudo losetup -d "$loop"
loop=""

# --- Hekate FAT/partition repack ---
"$HOME/switch-cros/bin/hekate-fix-gpt-mbr.py" "$image"
tmp_image="${image}.hekate-repack.$$"
"$HOME/switch-cros/bin/repack-hekate-physical-layout.py" "$image" "$tmp_image"
mv -f "$tmp_image" "$image"

# --- Pre-create stateful directories + freshly-format boot FAT ---
# TODO: stateful pre-creation is almost certainly redundant now that
# chromeos_startup runs cleanly; try deleting after the platform2 patches
# land and see if anything regresses.
loop=$(sudo losetup --find --partscan --show "$image")
boot_part="${loop}p1"
root_part="${loop}p3"
state_part="${loop}p12"

sudo mount "$state_part" "$state_mnt"
sudo mkdir -p \
  "$state_mnt/home/chronos" \
  "$state_mnt/home/user" \
  "$state_mnt/home/root" \
  "$state_mnt/unencrypted/cache" \
  "$state_mnt/unencrypted/preserve" \
  "$state_mnt/var/cache" \
  "$state_mnt/var/db/pkg" \
  "$state_mnt/var/lib/dbus" \
  "$state_mnt/var/lib/metrics" \
  "$state_mnt/var/lib/timezone" \
  "$state_mnt/var/lock" \
  "$state_mnt/var/log/metrics" \
  "$state_mnt/var/run"
sudo chmod 0755 \
  "$state_mnt/home" \
  "$state_mnt/home/chronos" \
  "$state_mnt/home/user" \
  "$state_mnt/unencrypted" \
  "$state_mnt/unencrypted/cache" \
  "$state_mnt/unencrypted/preserve" \
  "$state_mnt/var" \
  "$state_mnt/var/cache" \
  "$state_mnt/var/db" \
  "$state_mnt/var/db/pkg" \
  "$state_mnt/var/lib" \
  "$state_mnt/var/lib/dbus" \
  "$state_mnt/var/lib/metrics" \
  "$state_mnt/var/lib/timezone" \
  "$state_mnt/var/lock" \
  "$state_mnt/var/log/metrics" \
  "$state_mnt/var/run"
sudo chmod 1755 "$state_mnt/home/root"
sudo chmod 1775 "$state_mnt/var/log"
sudo umount "$state_mnt"

# Re-create boot FAT with the right hidden-sector count (Hekate/U-Boot are
# pickier about the BPB than Linux).
boot_start=$(lsblk -ndo START "$boot_part" | tr -d ' ')
sudo mkfs.vfat -F "$boot_fat_bits" -n SWITCHROOT \
  -h "$boot_start" "$boot_part" >/dev/null

sudo mount "$boot_part" "$boot_mnt"
sudo mount "$root_part" "$root_mnt"
sudo mkdir -p "$boot_mnt/switchroot/$os_dir" "$boot_mnt/bootloader/ini"

# Bootstack files live in the rootfs (installed by BSP ebuild from
# /usr/share/switch-t210/bootstack/); copy what U-Boot/Hekate need to the
# FAT boot partition.
bootstack="$root_mnt/usr/share/switch-t210/bootstack"
for f in uImage nx-plat.dtimg initramfs boot.scr bl31.bin bl33.bin \
         README_CONFIG.txt icon_chromiumos_hue.bmp bootlogo_chromiumos.bmp; do
  [[ -f "$bootstack/$f" ]] && sudo cp "$bootstack/$f" \
    "$boot_mnt/switchroot/$os_dir/"
done
sudo cp "$bootstack/switch-t210.ini" "$boot_mnt/bootloader/ini/chromiumos.ini"

sudo umount "$root_mnt"
sudo umount "$boot_mnt"
sudo losetup -d "$loop"
loop=""

echo "Installed Switchroot/Hekate ChromiumOS payload to $image"
