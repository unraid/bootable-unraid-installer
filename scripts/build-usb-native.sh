#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build a native GPT USB image (non-hybrid) with optional RW persistence.

Layout:
  p1  BIOS boot   (bios_grub)
  p2  EFI system  (FAT32)
  p3  ROOT/BOOT   (ext4, contains onboarding payload)
  p4  PERSIST     (ext4/exfat, seeded from persistent/) [optional]

Usage:
  ./build-usb-native.sh [options]

Options:
  --iso PATH               Source onboarding ISO (default: ./onboarding.iso, then ./test.iso)
  --output PATH            Output image path (default: ./zfs-live-build/onboarding-usb-native.img)
  --size SIZE|auto         Total image size (default: auto)
  --bios-mib N             BIOS boot partition size MiB (default: 4)
  --efi-mib N              EFI partition size MiB (default: 256)
  --root-mib N             ROOT partition size floor MiB for auto sizing (default: 256)
  --persist-mib N          Persistence partition size MiB (default: 1536)
  --persist-autoexpand     Add kernel arg persist_autoexpand=1 for boot-time persistence expansion
  --persist-fs ext4|exfat|fat32|vfat  Persistence filesystem (default: ext4)
  --no-persist             Do not create persistence partition (3-partition image)
  --seed-dir PATH          Seed directory (default: <repo>/persistent)
  --unraid-release-lock PATH  Seeded Unraid release lock file (default: build/unraid-release-lock.json)
  --tmp-dir PATH           Temp working directory (default: <output-dir>/.tmp-build-usb-native)
  --force                  Overwrite output image if it exists
  -h, --help               Show help

Notes:
- This script avoids hybrid ISO partition edits.
- GRUB is installed for both BIOS and UEFI.
- GRUB root selection uses filesystem UUID (not label).
EOF
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Missing required command: $cmd" >&2
    exit 1
  }
}

host_free_bytes_for_path() {
  local target_path="$1"
  local target_dir=""
  local free_bytes=""

  target_dir="$(dirname "$target_path")"
  mkdir -p "$target_dir"
  free_bytes="$(df -B1 "$target_dir" 2>/dev/null | awk 'NR==2 {print $4; exit}')"
  if [[ "$free_bytes" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$free_bytes"
    return 0
  fi
  return 1
}

iso_payload_size_bytes() {
  local iso_path="$1"
  local mnt=""
  local payload_bytes=""

  mnt="$(make_temp_dir)"
  if ! sudo mount -o loop,ro "$iso_path" "$mnt" >/dev/null 2>&1; then
    rmdir "$mnt" >/dev/null 2>&1 || true
    return 1
  fi

  payload_bytes="$(dir_size_bytes "$mnt" 2>/dev/null || true)"
  sudo umount "$mnt" >/dev/null 2>&1 || sudo umount -l "$mnt" >/dev/null 2>&1 || true
  rmdir "$mnt" >/dev/null 2>&1 || true

  [[ "$payload_bytes" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$payload_bytes"
}

resolve_default_iso_path() {
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"

  if [[ -f "$script_dir/onboarding.iso" ]]; then
    printf '%s\n' "$script_dir/onboarding.iso"
    return 0
  fi
  if [[ -f "$script_dir/test.iso" ]]; then
    printf '%s\n' "$script_dir/test.iso"
    return 0
  fi
  return 1
}

ensure_tmp_base() {
  if [[ -z "$TMP_BASE" ]]; then
    TMP_BASE="$(dirname "$OUTPUT_PATH")/.tmp-build-usb-native"
  fi
  mkdir -p "$TMP_BASE"
}

make_temp_dir() {
  ensure_tmp_base
  mktemp -d -p "$TMP_BASE" native.XXXXXX
}

part_dev_path() {
  local disk_dev="$1"
  local part_no="$2"

  if [[ -b "${disk_dev}p${part_no}" ]]; then
    printf '%s\n' "${disk_dev}p${part_no}"
    return 0
  fi
  if [[ -b "${disk_dev}${part_no}" ]]; then
    printf '%s\n' "${disk_dev}${part_no}"
    return 0
  fi
  return 1
}

seed_item_allowed() {
  local base_name="$1"

  case "$base_name" in
    zips|logs)
      return 0
      ;;
  esac
  return 1
}

dir_size_bytes() {
  local dir_path="$1"
  local bytes=""

  if bytes="$(du -sb "$dir_path" 2>/dev/null | awk '{print $1; exit}')" && [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$bytes"
    return 0
  fi

  if bytes="$(du -sk "$dir_path" 2>/dev/null | awk '{print $1; exit}')" && [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '%s\n' $(( bytes * 1024 ))
    return 0
  fi

  return 1
}

seed_size_bytes_for_profile() {
  local seed_dir="$1"
  local total=0
  local entry=""
  local base=""
  local entry_bytes=""

  [[ -d "$seed_dir" ]] || {
    printf '%s\n' 0
    return 0
  }

  while IFS= read -r -d '' entry; do
    base="$(basename "$entry")"
    if ! seed_item_allowed "$base"; then
      continue
    fi
    entry_bytes="$(dir_size_bytes "$entry" 2>/dev/null || echo 0)"
    [[ "$entry_bytes" =~ ^[0-9]+$ ]] && total=$(( total + entry_bytes ))
  done < <(find "$seed_dir" -mindepth 1 -maxdepth 1 -print0)

  printf '%s\n' "$total"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ISO_PATH=""
OUTPUT_PATH="./zfs-live-build/onboarding-usb-native.img"
IMAGE_SIZE="auto"
BIOS_MIB="4"
EFI_MIB="256"
ROOT_MIB="256"
PERSIST_MIB="1536"
PERSIST_FS="ext4"
PERSIST_LABEL="INSTALL-PERSIST"
PERSIST_VFAT_LABEL="INSTALLPERS"
SEED_DIR=""
SEED_DIR_DEFAULT="$REPO_ROOT/persistent"
UNRAID_RELEASE_LOCK_FILE="${UNRAID_RELEASE_LOCK_FILE:-$REPO_ROOT/build/unraid-release-lock.json}"
INSTALL_PROFILE="user"
PERSIST_AUTOEXPAND=0
NO_PERSIST=0
TMP_BASE=""
FORCE=0

while (($#)); do
  case "$1" in
    --iso)
      [[ $# -ge 2 ]] || { echo "Missing value for --iso" >&2; exit 1; }
      ISO_PATH="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "Missing value for --output" >&2; exit 1; }
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --size)
      [[ $# -ge 2 ]] || { echo "Missing value for --size" >&2; exit 1; }
      IMAGE_SIZE="$2"
      shift 2
      ;;
    --bios-mib)
      [[ $# -ge 2 ]] || { echo "Missing value for --bios-mib" >&2; exit 1; }
      BIOS_MIB="$2"
      shift 2
      ;;
    --efi-mib)
      [[ $# -ge 2 ]] || { echo "Missing value for --efi-mib" >&2; exit 1; }
      EFI_MIB="$2"
      shift 2
      ;;
    --root-mib)
      [[ $# -ge 2 ]] || { echo "Missing value for --root-mib" >&2; exit 1; }
      ROOT_MIB="$2"
      shift 2
      ;;
    --persist-mib)
      [[ $# -ge 2 ]] || { echo "Missing value for --persist-mib" >&2; exit 1; }
      PERSIST_MIB="$2"
      shift 2
      ;;
    --persist-autoexpand)
      PERSIST_AUTOEXPAND=1
      shift
      ;;
    --persist-fs)
      [[ $# -ge 2 ]] || { echo "Missing value for --persist-fs" >&2; exit 1; }
      PERSIST_FS="$2"
      shift 2
      ;;
    --no-persist)
      NO_PERSIST=1
      shift
      ;;
    --seed-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for --seed-dir" >&2; exit 1; }
      SEED_DIR="$2"
      shift 2
      ;;
    --unraid-release-lock)
      [[ $# -ge 2 ]] || { echo "Missing value for --unraid-release-lock" >&2; exit 1; }
      UNRAID_RELEASE_LOCK_FILE="$2"
      shift 2
      ;;
    --tmp-dir)
      [[ $# -ge 2 ]] || { echo "Missing value for --tmp-dir" >&2; exit 1; }
      TMP_BASE="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ "$BIOS_MIB" =~ ^[0-9]+$ ]] || { echo "--bios-mib must be an integer" >&2; exit 1; }
[[ "$EFI_MIB" =~ ^[0-9]+$ ]] || { echo "--efi-mib must be an integer" >&2; exit 1; }
[[ "$ROOT_MIB" =~ ^[0-9]+$ ]] || { echo "--root-mib must be an integer" >&2; exit 1; }
[[ "$PERSIST_MIB" =~ ^[0-9]+$ ]] || { echo "--persist-mib must be an integer" >&2; exit 1; }

if [[ "$NO_PERSIST" -eq 1 ]]; then
  PERSIST_MIB=0
  PERSIST_AUTOEXPAND=0
fi

PERSIST_FS="${PERSIST_FS,,}"
case "$PERSIST_FS" in
  ext4|exfat|fat32|vfat) ;;
  *) echo "Unsupported --persist-fs '$PERSIST_FS' (use ext4, exfat, fat32, or vfat)" >&2; exit 1 ;;
esac

if [[ "$INSTALL_PROFILE" != "user" ]]; then
  echo "INSTALL_PROFILE must be 'user' in the build chain (got: $INSTALL_PROFILE)" >&2
  exit 1
fi

if [[ -z "$ISO_PATH" ]]; then
  ISO_PATH="$(resolve_default_iso_path || true)"
fi
[[ -n "$ISO_PATH" ]] || { echo "No ISO provided and no default ISO found." >&2; exit 1; }
[[ -f "$ISO_PATH" ]] || { echo "ISO not found: $ISO_PATH" >&2; exit 1; }

if [[ -z "$SEED_DIR" ]]; then
  SEED_DIR="$SEED_DIR_DEFAULT"
fi

[[ -d "$SEED_DIR" ]] || { echo "Seed directory not found: $SEED_DIR" >&2; exit 1; }

echo "Resolved seed directory: $SEED_DIR"
echo "Unraid release lock: $UNRAID_RELEASE_LOCK_FILE"

read_unraid_release_lock() {
  local lock_file="$1"

  python3 - "$lock_file" <<'PY'
import json
import re
import sys
import urllib.parse
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(f"Unraid release lock not found: {path}")
lock = json.loads(path.read_text())
required = ["name", "version", "url", "filename", "sha256"]
missing = [key for key in required if not lock.get(key)]
if missing:
    raise SystemExit(f"Unraid release lock missing required fields: {', '.join(missing)}")
parsed = urllib.parse.urlsplit(lock["url"])
if parsed.scheme != "https" or parsed.netloc != "releases.unraid.net":
    raise SystemExit("Unraid release lock URL must use https://releases.unraid.net")
if not re.fullmatch(r"[0-9a-f]{64}", lock["sha256"]):
    raise SystemExit("Unraid release lock sha256 must be 64 lowercase hex characters")
url_sha256 = lock.get("url_sha256")
if url_sha256 and not re.fullmatch(r"[0-9a-f]{64}", url_sha256):
    raise SystemExit("Unraid release lock url_sha256 must be 64 lowercase hex characters when present")
print("\t".join([lock["name"], lock["version"], lock["url"], lock["filename"], lock["sha256"]]))
PY
}

if [[ "$NO_PERSIST" -eq 1 ]]; then
  seed_bytes=0
  effective_persist_mib=0
else
  seed_bytes="$(seed_size_bytes_for_profile "$SEED_DIR")"
  persist_headroom_bytes=$(( 256 * 1024 * 1024 ))
  required_persist_mib=$(( (seed_bytes + persist_headroom_bytes + 1024 * 1024 - 1) / (1024 * 1024) ))
  if (( required_persist_mib < PERSIST_MIB )); then
    effective_persist_mib="$PERSIST_MIB"
  else
    effective_persist_mib="$required_persist_mib"
  fi
fi

require_cmd truncate
require_cmd stat
require_cmd blockdev
require_cmd losetup
require_cmd partprobe
require_cmd udevadm
require_cmd parted
require_cmd lsblk
require_cmd blkid
require_cmd mkfs.vfat
require_cmd mount
require_cmd umount
require_cmd cp
require_cmd find
require_cmd grub-install
require_cmd grub-mkstandalone
require_cmd df
if [[ "$NO_PERSIST" -eq 0 ]]; then
  if [[ "$PERSIST_FS" == "ext4" ]]; then
    require_cmd mkfs.ext4
  elif [[ "$PERSIST_FS" == "exfat" ]]; then
    require_cmd mkfs.exfat
  else
    require_cmd mkfs.vfat
  fi
fi

if [[ -e "$OUTPUT_PATH" && "$FORCE" -ne 1 ]]; then
  echo "Output image exists: $OUTPUT_PATH" >&2
  echo "Use --force to overwrite." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
if [[ "$FORCE" -eq 1 && -e "$OUTPUT_PATH" ]]; then
  rm -f "$OUTPUT_PATH"
fi

iso_size_bytes="$(stat -c%s "$ISO_PATH")"
iso_payload_bytes="$(iso_payload_size_bytes "$ISO_PATH" 2>/dev/null || echo "$iso_size_bytes")"
root_required_mib=$(( (iso_payload_bytes + (64 * 1024 * 1024) + 1024 * 1024 - 1) / (1024 * 1024) ))
root_payload_mib="$ROOT_MIB"
if (( root_payload_mib < root_required_mib )); then
  root_payload_mib="$root_required_mib"
fi
if [[ "$IMAGE_SIZE" == "auto" ]]; then
  total_mib=$(( 1 + BIOS_MIB + EFI_MIB + root_payload_mib + effective_persist_mib + 32 ))
  total_bytes=$(( total_mib * 1024 * 1024 ))
  host_free_bytes="$(host_free_bytes_for_path "$OUTPUT_PATH" 2>/dev/null || echo 0)"
  if [[ "$host_free_bytes" =~ ^[0-9]+$ ]] && (( host_free_bytes > 0 )) && (( host_free_bytes < total_bytes )); then
    echo "Not enough host free space for output image." >&2
    echo "Required: $total_bytes bytes, available: $host_free_bytes bytes" >&2
    exit 1
  fi
  echo "Creating raw image: $OUTPUT_PATH (auto, ${total_mib} MiB)"
  echo "Auto sizing: payload=${iso_payload_bytes} bytes, root=${root_payload_mib} MiB, seed=${seed_bytes} bytes, persist=${effective_persist_mib} MiB"
  truncate -s "$total_bytes" "$OUTPUT_PATH"
else
  echo "Creating raw image: $OUTPUT_PATH ($IMAGE_SIZE)"
  if [[ "$NO_PERSIST" -eq 1 ]]; then
    echo "Persistence disabled (--no-persist)"
  else
    echo "Persistence size: ${PERSIST_MIB} MiB (seed estimate: ${seed_bytes} bytes)"
  fi
  truncate -s "$IMAGE_SIZE" "$OUTPUT_PATH"
  effective_persist_mib="$PERSIST_MIB"
fi

LOOP_DEV=""
MNT_ISO=""
MNT_EFI=""
MNT_ROOT=""
MNT_PERSIST=""

cleanup() {
  if [[ -n "$MNT_PERSIST" && -d "$MNT_PERSIST" ]]; then
    sudo umount "$MNT_PERSIST" >/dev/null 2>&1 || sudo umount -l "$MNT_PERSIST" >/dev/null 2>&1 || true
    rmdir "$MNT_PERSIST" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MNT_ROOT" && -d "$MNT_ROOT" ]]; then
    sudo umount "$MNT_ROOT" >/dev/null 2>&1 || sudo umount -l "$MNT_ROOT" >/dev/null 2>&1 || true
    rmdir "$MNT_ROOT" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MNT_EFI" && -d "$MNT_EFI" ]]; then
    sudo umount "$MNT_EFI" >/dev/null 2>&1 || sudo umount -l "$MNT_EFI" >/dev/null 2>&1 || true
    rmdir "$MNT_EFI" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MNT_ISO" && -d "$MNT_ISO" ]]; then
    sudo umount "$MNT_ISO" >/dev/null 2>&1 || sudo umount -l "$MNT_ISO" >/dev/null 2>&1 || true
    rmdir "$MNT_ISO" >/dev/null 2>&1 || true
  fi
  if [[ -n "$LOOP_DEV" ]]; then
    sudo losetup -d "$LOOP_DEV" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

LOOP_DEV="$(sudo losetup --find --show --partscan "$OUTPUT_PATH")"
disk_bytes="$(sudo blockdev --getsize64 "$LOOP_DEV")"
disk_mib=$(( disk_bytes / 1024 / 1024 ))

p1_start=1
p1_end=$(( p1_start + BIOS_MIB ))
p2_start=$p1_end
p2_end=$(( p2_start + EFI_MIB ))
p3_start=$p2_end
if [[ "$NO_PERSIST" -eq 1 ]]; then
  p3_end=$(( disk_mib - 1 ))
else
  p4_end=$(( disk_mib - 1 ))
  p4_start=$(( p4_end - effective_persist_mib ))
  p3_end=$p4_start
fi
p3_size_mib=$(( p3_end - p3_start ))

if (( p3_end <= p3_start + 64 )); then
  echo "Image too small for native layout. Increase --size or reduce reservations." >&2
  exit 1
fi
if (( p3_size_mib < root_required_mib )); then
  echo "ROOT partition too small for ISO payload." >&2
  echo "Required (estimated): ${root_required_mib} MiB, available: ${p3_size_mib} MiB" >&2
  echo "Increase --size, reduce --persist-mib, or use --size auto." >&2
  exit 1
fi

echo "Partitioning $LOOP_DEV (GPT native layout)..."
sudo parted -s "$LOOP_DEV" mklabel gpt
sudo parted -s "$LOOP_DEV" unit MiB mkpart primary "${p1_start}" "${p1_end}"
sudo parted -s "$LOOP_DEV" name 1 BIOS-BOOT
sudo parted -s "$LOOP_DEV" set 1 bios_grub on

sudo parted -s "$LOOP_DEV" unit MiB mkpart ESP fat32 "${p2_start}" "${p2_end}"
sudo parted -s "$LOOP_DEV" name 2 EFI-SYSTEM
sudo parted -s "$LOOP_DEV" set 2 esp on

sudo parted -s "$LOOP_DEV" unit MiB mkpart primary ext4 "${p3_start}" "${p3_end}"
sudo parted -s "$LOOP_DEV" name 3 INSTALL-ROOT

if [[ "$NO_PERSIST" -eq 0 ]]; then
  sudo parted -s "$LOOP_DEV" unit MiB mkpart primary "${p4_start}" "100%"
  sudo parted -s "$LOOP_DEV" name 4 INSTALL-PERSIST
  case "$PERSIST_FS" in
    fat32|vfat|exfat)
      # Use Microsoft basic data GPT type so Windows will expose the volume.
      sudo parted -s "$LOOP_DEV" set 4 msftdata on
      ;;
  esac
fi

sudo partprobe "$LOOP_DEV" || true
sudo udevadm settle || true

P2="$(part_dev_path "$LOOP_DEV" 2)"
P3="$(part_dev_path "$LOOP_DEV" 3)"
if [[ "$NO_PERSIST" -eq 0 ]]; then
  P4="$(part_dev_path "$LOOP_DEV" 4)"
  [[ -b "$P2" && -b "$P3" && -b "$P4" ]] || { echo "Unable to resolve partition devices" >&2; exit 1; }
else
  [[ -b "$P2" && -b "$P3" ]] || { echo "Unable to resolve partition devices" >&2; exit 1; }
fi

echo "Formatting filesystems..."
sudo mkfs.vfat -F 32 -n INSTALL-EFI "$P2" >/dev/null
sudo mkfs.ext4 -F -L INSTALLER "$P3" >/dev/null
if [[ "$NO_PERSIST" -eq 0 ]]; then
  if [[ "$PERSIST_FS" == "ext4" ]]; then
    sudo mkfs.ext4 -F -L "$PERSIST_LABEL" "$P4" >/dev/null
  elif [[ "$PERSIST_FS" == "exfat" ]]; then
    sudo mkfs.exfat -n "$PERSIST_LABEL" "$P4" >/dev/null
  else
    sudo mkfs.vfat -F 32 -n "$PERSIST_VFAT_LABEL" "$P4" >/dev/null
  fi
fi

MNT_ISO="$(make_temp_dir)"
MNT_EFI="$(make_temp_dir)"
MNT_ROOT="$(make_temp_dir)"
if [[ "$NO_PERSIST" -eq 0 ]]; then
  MNT_PERSIST="$(make_temp_dir)"
fi

sudo mount -o loop,ro "$ISO_PATH" "$MNT_ISO"
sudo mount "$P2" "$MNT_EFI"
sudo mount "$P3" "$MNT_ROOT"
if [[ "$NO_PERSIST" -eq 0 ]]; then
  sudo mount "$P4" "$MNT_PERSIST"
fi

echo "Copying onboarding payload to ROOT partition..."
sudo cp -a "$MNT_ISO"/. "$MNT_ROOT"/
if [[ ! -d "$MNT_ROOT/boot" ]]; then
  if [[ -d "$MNT_ISO/boot" ]]; then
    echo "Copy failed before /boot was written (likely insufficient ROOT partition space)." >&2
    echo "Try --size auto or larger --size, or reduce --persist-mib." >&2
  else
    echo "Source ISO does not contain /boot. Verify --iso points to onboarding install ISO." >&2
  fi
  exit 1
fi

if [[ ! -f "$MNT_ROOT/boot/vmlinuz" || ! -f "$MNT_ROOT/boot/initrd" ]]; then
  echo "Copied payload is missing /boot/vmlinuz or /boot/initrd." >&2
  echo "Verify --iso points to the onboarding install ISO artifact." >&2
  exit 1
fi

root_uuid="$(sudo blkid -o value -s UUID "$P3" 2>/dev/null || true)"
[[ -n "$root_uuid" ]] || { echo "Unable to read ROOT UUID" >&2; exit 1; }

kernel_extra_args=""
if [[ "$NO_PERSIST" -eq 1 ]]; then
  kernel_extra_args=" persist_disable=1"
else
  if [[ "$PERSIST_AUTOEXPAND" -eq 1 ]]; then
    kernel_extra_args+=" persist_autoexpand=1"
  fi
  kernel_extra_args+=" persist_fs=${PERSIST_FS}"
fi

echo "Installing GRUB (BIOS + UEFI)..."
# Remove copied ISO GRUB configs that may reference ISO-only paths like /.disk/info.
sudo rm -f "$MNT_ROOT/boot/grub/grub.cfg" "$MNT_ROOT/boot/grub/loopback.cfg" >/dev/null 2>&1 || true
sudo rm -f "$MNT_ROOT/EFI/BOOT/grub.cfg" >/dev/null 2>&1 || true

sudo grub-install --target=i386-pc --boot-directory="$MNT_ROOT/boot" --recheck \
  --modules="part_gpt ext2 search search_fs_uuid" "$LOOP_DEV" >/dev/null

sudo tee "$MNT_ROOT/boot/grub/grub.cfg" >/dev/null <<EOF
set timeout=5
set timeout_style=menu
set default=0
insmod all_video
insmod gfxterm
insmod font
insmod png
insmod chain
insmod test
insmod echo
insmod search
insmod search_fs_uuid

if loadfont /boot/grub/themes/unraid/terminus-14.pf2 ; then
  set gfxmode=auto
  terminal_output gfxterm
  set theme=/boot/grub/themes/unraid/theme.txt
  export theme
else
  terminal_output console
fi

menuentry "Internal Boot Setup" {
  search --no-floppy --fs-uuid --set=root $root_uuid
  linux /boot/vmlinuz root=/dev/ram0 rw rdinit=/init loglevel=3 console=tty0 consoleblank=0${kernel_extra_args}
  initrd /boot/initrd
}

menuentry "Memtest86+" {
  search --no-floppy --fs-uuid --set=root $root_uuid
  if [ -f /boot/memtest86+x64.efi ]; then
    chainloader /boot/memtest86+x64.efi
    boot
  else
    echo "Memtest payload not found on boot media."
    echo "Expected /boot/memtest86+x64.efi"
  fi
}
EOF

sudo mkdir -p "$MNT_EFI/EFI/BOOT"
EFI_CHAIN_CFG="$(make_temp_dir)/grub-efi-chain.cfg"
cat > "$EFI_CHAIN_CFG" <<EOF
search --no-floppy --fs-uuid --set=root $root_uuid
set prefix=(\$root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

sudo grub-mkstandalone -O x86_64-efi \
  -o "$MNT_EFI/EFI/BOOT/BOOTX64.EFI" \
  --modules="part_gpt ext2 search search_fs_uuid normal linux configfile all_video efi_gop efi_uga gfxterm gfxmenu font png test echo chain" \
  "boot/grub/grub.cfg=$EFI_CHAIN_CFG" >/dev/null

sudo cp "$EFI_CHAIN_CFG" "$MNT_EFI/EFI/BOOT/grub.cfg"

if [[ "$NO_PERSIST" -eq 1 ]]; then
  echo "Persistence disabled; skipping seed copy."
elif [[ -d "$SEED_DIR" ]]; then
  seed_copy_mode="preserve"
  case "$PERSIST_FS" in
    ext4)
      seed_copy_mode="preserve"
      ;;
    exfat|fat32|vfat)
      seed_copy_mode="portable"
      ;;
  esac

  copy_seed_item() {
    local src_path="$1"

    if [[ "$seed_copy_mode" == "preserve" ]]; then
      # Preserve metadata but never ownership so copies work on FAT/exFAT and in restricted CI mounts.
      sudo cp -a --no-preserve=ownership "$src_path" "$MNT_PERSIST/"
    else
      sudo cp -R "$src_path" "$MNT_PERSIST/"
    fi
  }

  echo "Seeding persistence from: $SEED_DIR"
  echo "Persistence copy mode: $seed_copy_mode (fs: $PERSIST_FS)"
  while IFS= read -r -d '' seed_entry; do
    seed_base="$(basename "$seed_entry")"
    if ! seed_item_allowed "$seed_base"; then
      echo "Skipping non-user-build seed item: $seed_base"
      continue
    fi
    echo "Copying seed item: $seed_base"
    copy_seed_item "$seed_entry"
  done < <(find "$SEED_DIR" -mindepth 1 -maxdepth 1 -print0)
else
  echo "Seed directory not found, skipping seed copy: $SEED_DIR"
fi

if [[ "$NO_PERSIST" -ne 0 ]]; then
  echo "Skipping build-time zip download: persistence is disabled."
elif [[ ! -f "$SCRIPT_DIR/zip.sh" ]]; then
  echo "Skipping build-time zip download: missing script $SCRIPT_DIR/zip.sh"
else
  sudo mkdir -p "$MNT_PERSIST/zips"
  release_lock_line="$(read_unraid_release_lock "$UNRAID_RELEASE_LOCK_FILE")"
  IFS=$'\t' read -r unraid_release_name unraid_release_version unraid_release_url unraid_release_filename unraid_release_sha256 <<< "$release_lock_line"
  echo "Downloading pinned Unraid ${unraid_release_version} zip into persistence (build-time): ${unraid_release_filename}"
  if ! sudo /bin/bash "$SCRIPT_DIR/zip.sh" \
    --release-url "$unraid_release_url" \
    --release-name "$unraid_release_name" \
    --expected-sha256 "$unraid_release_sha256" \
    --non-interactive \
    --ui text \
    --zip-dir "$MNT_PERSIST/zips"; then
    echo "Failed to download pinned Unraid zip during build-time seeding." >&2
    exit 1
  fi

  sudo mkdir -p "$MNT_PERSIST/logs"
  provenance_tmp="$(mktemp)"
  python3 - "$UNRAID_RELEASE_LOCK_FILE" "$provenance_tmp" <<'PY'
import json
import sys
from pathlib import Path

lock = json.loads(Path(sys.argv[1]).read_text())
provenance = {
    "schema": 1,
    "kind": "seeded-unraid-release",
    "redistribution": "approved",
    "approval_note": "Official Unraid installer image may bundle Unraid OS as an alternative install method.",
    "release": lock,
}
Path(sys.argv[2]).write_text(json.dumps(provenance, indent=2) + "\n")
PY
  sudo cp "$provenance_tmp" "$MNT_PERSIST/logs/seeded-unraid-release.json"
  rm -f "$provenance_tmp"

  zip_count="$(find "$MNT_PERSIST/zips" -maxdepth 1 -type f -iname '*.zip' | wc -l | tr -d '[:space:]')"
  if [[ "$zip_count" == "0" ]]; then
    echo "Build-time zip download completed but no zip file was found in $MNT_PERSIST/zips" >&2
    exit 1
  fi
  echo "Build-time zip verification: ${zip_count} zip file(s) present in $MNT_PERSIST/zips"
fi

if [[ "$NO_PERSIST" -eq 0 ]]; then
  echo "Ensuring executable bit on copied shell scripts in persistence..."
  sudo find "$MNT_PERSIST" -type f -name '*.sh' -exec chmod +x {} +
fi

sync

echo "Finalizing image..."
if [[ -n "$MNT_PERSIST" ]]; then
  sudo umount "$MNT_PERSIST" || sudo umount -l "$MNT_PERSIST" || true
fi
sudo umount "$MNT_ROOT" || sudo umount -l "$MNT_ROOT" || true
sudo umount "$MNT_EFI" || sudo umount -l "$MNT_EFI" || true
sudo umount "$MNT_ISO" || sudo umount -l "$MNT_ISO" || true
if [[ -n "$MNT_PERSIST" ]]; then
  rmdir "$MNT_PERSIST" >/dev/null 2>&1 || true
fi
rmdir "$MNT_ROOT" "$MNT_EFI" "$MNT_ISO" >/dev/null 2>&1 || true
MNT_PERSIST=""
MNT_ROOT=""
MNT_EFI=""
MNT_ISO=""

sudo partprobe "$LOOP_DEV" || true
sudo udevadm settle || true

echo
echo "Native USB image created: $OUTPUT_PATH"
echo "ISO source: $ISO_PATH"
if [[ "$NO_PERSIST" -eq 1 ]]; then
  echo "Layout: BIOS-BOOT | EFI-SYSTEM | INSTALL-ROOT"
  echo "Persistence: disabled"
else
  echo "Layout: BIOS-BOOT | EFI-SYSTEM | INSTALL-ROOT | INSTALL-PERSIST"
  echo "Persistence fs: $PERSIST_FS"
fi
echo
echo "Write to USB with:"
echo "  sudo dd if=$OUTPUT_PATH of=/dev/sdX bs=4M status=progress conv=fsync"
