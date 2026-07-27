#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
 local cmd="$1"
 command -v "$cmd" >/dev/null 2>&1 || {
  echo "Missing required command: $cmd" >&2
  exit 1
 }
}

fatal() {
 echo "$*" >&2
 exit 1
}

read_lock_json_string() {
 local key="$1"
 local content="$2"

 printf '%s' "$content" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

load_version_lock() {
 local lock_file="${VERSION_LOCK_FILE:-$REPO_ROOT/build/version-lock.json}"
 local lock_content=""
 local lock_kernel_series=""
 local lock_kernel_version=""
 local lock_zfs_tag=""

 if [ ! -f "$lock_file" ]; then
  return 0
 fi

 lock_content="$(tr -d '\r\n' < "$lock_file")"
 lock_kernel_series="$(read_lock_json_string "kernel_series" "$lock_content")"
 lock_kernel_version="$(read_lock_json_string "kernel_version" "$lock_content")"
 lock_zfs_tag="$(read_lock_json_string "zfs_tag" "$lock_content")"

 if [ -n "$lock_kernel_series" ]; then
  KERNEL_SERIES="$lock_kernel_series"
 fi

 if [ -n "$lock_kernel_version" ]; then
  KERNEL_VERSION="$lock_kernel_version"
 fi

 if [ -n "$lock_zfs_tag" ]; then
  ZFS_TAG="$lock_zfs_tag"
 fi

 VERSION_LOCK_HASH="$(sha256sum "$lock_file" | awk '{print $1}')"
 echo "Using version lock file: $lock_file"
 echo "Version lock hash: $VERSION_LOCK_HASH"
 [ -n "$lock_kernel_version" ] && echo "Locked kernel version: $lock_kernel_version"
 [ -n "$lock_zfs_tag" ] && echo "Locked OpenZFS tag: $lock_zfs_tag"
}

kernel_config_overrides() {
 cat <<'EOF'
CONFIG_EFI=y
CONFIG_EFI_STUB=y
CONFIG_DRM=y
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_SYSFB=y
CONFIG_SYSFB_SIMPLEFB=y
CONFIG_DRM_SIMPLEDRM=y
CONFIG_FB=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_FB_EFI=y
CONFIG_PCI=y
CONFIG_PCI_MSI=y
CONFIG_PCIEPORTBUS=y
CONFIG_HOTPLUG_PCI_PCIE=y
CONFIG_BLK_DEV_NVME=y
CONFIG_NVME_CORE=y
CONFIG_VMD=y
EOF
}

apply_kernel_config_overrides() {
 local fragment_path="$WORKDIR/kernel-config-overrides.conf"
 local config_source="${KERNEL_CONFIG_FILE:-}"

 kernel_config_overrides > "$fragment_path"

 if [ -n "$config_source" ] && [ -f "$config_source" ]; then
  cp "$config_source" .config
  make olddefconfig
 else
  make "$KERNEL_CONFIG_TARGET"
 fi

 if [ -x "./scripts/kconfig/merge_config.sh" ]; then
  ./scripts/kconfig/merge_config.sh -m .config "$fragment_path"
 else
  cat "$fragment_path" >> .config
 fi

 make olddefconfig
}

MOUNTS_TO_CLEAN=()

register_mount() {
 MOUNTS_TO_CLEAN+=("$1")
}

bind_mount() {
 local source_path="$1"
 local mount_point="$2"

 sudo mkdir -p "$mount_point"
 if ! mountpoint -q "$mount_point"; then
  sudo mount --bind "$source_path" "$mount_point"
  register_mount "$mount_point"
 fi
}

cleanup() {
 local status=$?
 local idx mp

 for ((idx=${#MOUNTS_TO_CLEAN[@]}-1; idx>=0; idx--)); do
  mp="${MOUNTS_TO_CLEAN[$idx]}"
  if mountpoint -q "$mp"; then
   sudo umount "$mp" || sudo umount -l "$mp" || true
  fi
 done

 trap - EXIT INT TERM
 exit "$status"
}
trap cleanup EXIT INT TERM

unmount_rootfs_runtime_mounts() {
 local mount_path

 for mount_path in "$ROOTFS/run" "$ROOTFS/sys" "$ROOTFS/proc" "$ROOTFS/dev"; do
  if mountpoint -q "$mount_path"; then
   sudo umount "$mount_path" || sudo umount -l "$mount_path" || true
  fi
 done

 MOUNTS_TO_CLEAN=()
}

KERNEL_SERIES="${KERNEL_SERIES:-6.18}"
KERNEL_VERSION="${KERNEL_VERSION:-}"
ZFS_TAG="${ZFS_TAG:-}"
VERSION_LOCK_HASH=""
CLEAN_BUILD="${CLEAN_BUILD:-0}"
MODE="full"
INSTALL_PROFILE="${INSTALL_PROFILE:-user}"
MENU_UI="${MENU_UI:-gui}"
MENU_BACKEND_DEFAULT="${MENU_BACKEND_DEFAULT:-}"
BOOT_PERSIST_FS="${BOOT_PERSIST_FS:-}"
BOOT_PERSIST_RECREATE_ON_RESIZE_FAIL="${BOOT_PERSIST_RECREATE_ON_RESIZE_FAIL:-0}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}"
UBUNTU_MIRROR="${UBUNTU_MIRROR:-https://archive.ubuntu.com/ubuntu/}"
UBUNTU_SECURITY_MIRROR="${UBUNTU_SECURITY_MIRROR:-https://security.ubuntu.com/ubuntu/}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNGRUB_SRC=""
UNGRUB_THEME_SRC=""
UNGRUB_WEBGUI_REPO="${UNGRUB_WEBGUI_REPO:-https://github.com/unraid/webgui.git}"
UNGRUB_WEBGUI_REF="${UNGRUB_WEBGUI_REF:-}"
DEFAULT_KERNEL_CONFIG_FILE="$SCRIPT_DIR/config"
DISPLAY_NAME="${DISPLAY_NAME:-Internal Boot Setup}"
STATIC_HOSTNAME="${STATIC_HOSTNAME:-internal-boot-setup}"
PRETTY_HOSTNAME="${PRETTY_HOSTNAME:-Internal Boot Setup}"
WORKDIR="${WORKDIR:-$REPO_ROOT/zfs-live-build}"
UNGRUB_WORKTREE="$WORKDIR/webgui"
ROOTFS="$WORKDIR/rootfs"
ISO="$WORKDIR/iso"
ISO_THEME_DIR="$ISO/boot/grub/themes/unraid"
KERNEL_STAGING_DIR="$WORKDIR/kernel-staging"
ROOTFS_MIN_FREE_KB="${ROOTFS_MIN_FREE_KB:-4194304}"
KERNEL_CONFIG_TARGET="defconfig"
KERNEL_CONFIG_FILE="${KERNEL_CONFIG_FILE:-}"
ZFS_SRC_DIR="$WORKDIR/zfs"
ZFS_USERSPACE_STAGING_DIR="$WORKDIR/zfs-userspace-staging"
PUBLISH_ISO="${PUBLISH_ISO:-$WORKDIR/onboarding.iso}"
MEDIA_LABEL="${MEDIA_LABEL:-INSTALLER}"
ONBOARDING_ASSET_DIR="$ROOTFS/boot/install"

while (($#)); do
 case "$1" in
   full|grub-iso|cache-only)
      MODE="$1"
      shift
      ;;
   --clean)
      CLEAN_BUILD=1
      shift
      ;;
   --menu-ui)
      [ "$#" -ge 2 ] || { echo "Missing value for --menu-ui" >&2; exit 1; }
      MENU_UI="$2"
      shift 2
      ;;
   --menu-backend)
      [ "$#" -ge 2 ] || { echo "Missing value for --menu-backend" >&2; exit 1; }
      MENU_BACKEND_DEFAULT="$2"
      shift 2
      ;;
   --persist-fs)
      [ "$#" -ge 2 ] || { echo "Missing value for --persist-fs" >&2; exit 1; }
      BOOT_PERSIST_FS="$2"
      shift 2
      ;;
   -h|--help)
      cat <<'EOF'
Usage:
   ./build-iso.sh [full|grub-iso|cache-only] [--clean] [--menu-ui gui] [--menu-backend auto|whiptail|dialog|text] [--persist-fs ext4|fat32|vfat] [--persist-recreate-on-resize-fail]

Options:
   --clean   Remove kernel/ZFS build artifacts and force recompilation (full/cache-only mode).
   --menu-ui Select default onboarding menu implementation (gui only).
   --menu-backend Set default menu backend (auto, whiptail, dialog, text).
   --persist-fs Set default persistence filesystem for auto-create at boot.
   --persist-recreate-on-resize-fail Enable vfat backup+recreate fallback when resize fails.
EOF
      exit 0
      ;;
   --persist-recreate-on-resize-fail)
      BOOT_PERSIST_RECREATE_ON_RESIZE_FAIL=1
      shift
      ;;
   *)
      echo "Unknown argument: $1" >&2
      echo "Mode must be 'full', 'grub-iso', or 'cache-only'" >&2
      exit 1
      ;;
 esac
done

UBUNTU_MIRROR="${UBUNTU_MIRROR%/}/"
UBUNTU_SECURITY_MIRROR="${UBUNTU_SECURITY_MIRROR%/}/"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

load_version_lock

if [ -n "$VERSION_LOCK_HASH" ]; then
 KERNEL_VERSION_FILE="$WORKDIR/.kernel-version-$VERSION_LOCK_HASH"
 ZFS_TAG_FILE="$WORKDIR/.zfs-tag-$VERSION_LOCK_HASH"
else
 KERNEL_VERSION_FILE="$WORKDIR/.kernel-version"
 ZFS_TAG_FILE="$WORKDIR/.zfs-tag"
fi

if [ -z "$KERNEL_CONFIG_FILE" ] && [ -f "$DEFAULT_KERNEL_CONFIG_FILE" ]; then
 KERNEL_CONFIG_FILE="$DEFAULT_KERNEL_CONFIG_FILE"
fi

if [ -n "$KERNEL_CONFIG_FILE" ] && [ ! -f "$KERNEL_CONFIG_FILE" ]; then
 echo "KERNEL_CONFIG_FILE does not exist: $KERNEL_CONFIG_FILE" >&2
 exit 1
fi

if [ -n "$KERNEL_CONFIG_FILE" ]; then
 echo "Using kernel config file: $KERNEL_CONFIG_FILE"
else
 echo "Using kernel config target: $KERNEL_CONFIG_TARGET"
fi

case "$MODE" in
 full|grub-iso|cache-only) ;;
 *)
    echo "Mode must be 'full', 'grub-iso', or 'cache-only'" >&2
   exit 1
   ;;
esac

if [ "$CLEAN_BUILD" = "1" ] && [ "$MODE" = "grub-iso" ]; then
 echo "--clean is supported only with 'full' or 'cache-only' mode." >&2
 exit 1
fi

if [ "$INSTALL_PROFILE" != "user" ]; then
   echo "INSTALL_PROFILE must be 'user' in the build chain (got: $INSTALL_PROFILE)" >&2
   exit 1
fi

case "$MENU_UI" in
 gui) ;;
 *)
    echo "MENU_UI must be 'gui' (got: $MENU_UI)" >&2
   exit 1
   ;;
esac

case "${MENU_BACKEND_DEFAULT,,}" in
 ""|auto)
    MENU_BACKEND_DEFAULT=""
    ;;
 whiptail|dialog|text)
    MENU_BACKEND_DEFAULT="${MENU_BACKEND_DEFAULT,,}"
    ;;
 *)
    echo "--menu-backend must be auto, whiptail, dialog, or text (got: $MENU_BACKEND_DEFAULT)" >&2
    exit 1
    ;;
esac

if [ -n "$BOOT_PERSIST_FS" ]; then
 case "${BOOT_PERSIST_FS,,}" in
   ext4|fat32|vfat)
    BOOT_PERSIST_FS="${BOOT_PERSIST_FS,,}"
    ;;
   *)
    echo "--persist-fs must be ext4, fat32, or vfat (got: $BOOT_PERSIST_FS)" >&2
    exit 1
    ;;
 esac
fi

BOOT_PERSIST_KERNEL_ARGS=""
if [ -n "$BOOT_PERSIST_FS" ]; then
 BOOT_PERSIST_KERNEL_ARGS=" persist_fs=$BOOT_PERSIST_FS"
fi
if [ "$BOOT_PERSIST_RECREATE_ON_RESIZE_FAIL" = "1" ]; then
 BOOT_PERSIST_KERNEL_ARGS+=" persist_recreate_on_resize_fail=1"
fi

require_cmd tar
require_cmd xz
require_cmd cpio
require_cmd gzip
require_cmd depmod
require_cmd mountpoint
require_cmd xorriso
require_cmd grub-mkstandalone
require_cmd grub-mkimage
require_cmd mkfs.vfat
require_cmd mmd
require_cmd mcopy
require_cmd git
if [ "$MODE" = "full" ]; then
 require_cmd debootstrap
 require_cmd dpkg-deb
fi

download_to_file() {
 local url="$1"
 local out="$2"

 if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url" -o "$out"
  return
 fi

 if command -v wget >/dev/null 2>&1; then
  wget -qO "$out" "$url"
  return
 fi

 echo "Missing required command: curl or wget" >&2
 exit 1
}

sync_ungrub_from_webgui() {
 echo "Syncing ungrub from $UNGRUB_WEBGUI_REPO..."
 rm -rf "$UNGRUB_WORKTREE"

 if [ -n "$UNGRUB_WEBGUI_REF" ]; then
  git clone --depth 1 --branch "$UNGRUB_WEBGUI_REF" "$UNGRUB_WEBGUI_REPO" "$UNGRUB_WORKTREE"
 else
  git clone --depth 1 "$UNGRUB_WEBGUI_REPO" "$UNGRUB_WORKTREE"
 fi

 UNGRUB_SRC="$UNGRUB_WORKTREE/ungrub"
 UNGRUB_THEME_SRC="$UNGRUB_SRC/themes/unraid"

 [ -d "$UNGRUB_SRC" ] || {
  echo "Missing ungrub directory in webgui repository checkout: $UNGRUB_SRC" >&2
  exit 1
 }

 echo "Using ungrub source: $UNGRUB_SRC"
}

sync_ungrub_from_webgui

resolve_isohybrid_mbr_path() {
 local candidate

 for candidate in \
  /usr/lib/ISOLINUX/isohdpfx.bin \
  /usr/lib/syslinux/isohdpfx.bin \
  /usr/lib/syslinux/bios/isohdpfx.bin; do
  if [ -f "$candidate" ]; then
   printf '%s\n' "$candidate"
   return 0
  fi
 done

 return 1
}

resolve_grub_cdboot_path() {
 local candidate

 for candidate in \
  /usr/lib/grub/i386-pc/cdboot.img \
  /usr/lib/grub/i386-pc/eltorito.img; do
  if [ -f "$candidate" ]; then
   printf '%s\n' "$candidate"
   return 0
  fi
 done

 return 1
}

resolve_latest_zfs_tag() {
 local tmp_metadata tag

 tmp_metadata="$(mktemp)"
 if ! download_to_file "https://api.github.com/repos/openzfs/zfs/releases/latest" "$tmp_metadata"; then
   rm -f "$tmp_metadata"
   fatal "Unable to download latest OpenZFS release metadata"
 fi

 tag="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp_metadata" | head -n1)"
 rm -f "$tmp_metadata"

 case "$tag" in
   zfs-[0-9]*.[0-9]*.[0-9]*)
    printf '%s\n' "$tag"
    ;;
   *)
    fatal "Unable to resolve latest OpenZFS release tag"
    ;;
 esac
}

normalize_zfs_tag() {
 local raw_tag="$1"

 case "$raw_tag" in
    zfs-[0-9]*.[0-9]*.[0-9]*)
      printf '%s\n' "$raw_tag"
      return 0
      ;;
    [0-9]*.[0-9]*.[0-9]*)
      printf 'zfs-%s\n' "$raw_tag"
      return 0
      ;;
 esac

 return 1
}

resolve_zfs_tag() {
 local requested_tag="${ZFS_TAG:-}"
 local cached_tag=""
 local normalized_tag=""

 if [ -n "$requested_tag" ]; then
    if normalized_tag="$(normalize_zfs_tag "$requested_tag")"; then
         printf '%s\n' "$normalized_tag"
         return 0
    fi
    fatal "Invalid ZFS_TAG '$requested_tag'. Expected X.Y.Z or zfs-X.Y.Z"
 fi

 if [ -f "$ZFS_TAG_FILE" ]; then
   cached_tag="$(head -n1 "$ZFS_TAG_FILE" | tr -d '[:space:]')"
    if normalized_tag="$(normalize_zfs_tag "$cached_tag")"; then
         printf '%s\n' "$normalized_tag"
         return 0
    fi
    echo "Ignoring invalid cached OpenZFS tag in $ZFS_TAG_FILE: ${cached_tag:-<empty>}" >&2
 fi

 resolve_latest_zfs_tag
}

resolve_kernel_version() {
 local requested_version="${KERNEL_VERSION:-}"
 local series="$KERNEL_SERIES"
 local cached_version=""
 local tmp_metadata versions latest_version

 if [ -f "$KERNEL_VERSION_FILE" ]; then
    cached_version="$(head -n1 "$KERNEL_VERSION_FILE" | tr -d '[:space:]')"
    case "$cached_version" in
      *.*.*)
         printf '%s\n' "$cached_version"
         return
         ;;
    esac
 fi

 if [ -n "$requested_version" ]; then
   case "$requested_version" in
    *.*.*)
      printf '%s\n' "$requested_version"
      return
      ;;
    *.*)
      series="$requested_version"
      ;;
    *)
      echo "Invalid KERNEL_VERSION '$requested_version'. Use X.Y for a series or X.Y.Z for an exact version." >&2
      exit 1
      ;;
   esac
 fi

 tmp_metadata="$(mktemp)"

 if ! download_to_file "https://www.kernel.org/releases.json" "$tmp_metadata"; then
   rm -f "$tmp_metadata"
  echo "Unable to download kernel release metadata from kernel.org" >&2
  exit 1
 fi

 versions="$(grep -o '"version":[[:space:]]*"'"$series"'\.[0-9][0-9]*"' "$tmp_metadata" | sed -E 's/.*"([0-9.]+)"/\1/' | sort -V | uniq)"
 rm -f "$tmp_metadata"
 latest_version="$(printf '%s\n' "$versions" | tail -n1)"

 if [ -z "$latest_version" ]; then
  echo "Unable to find a kernel.org release for series $series" >&2
  exit 1
 fi

 printf '%s\n' "$latest_version" > "$KERNEL_VERSION_FILE"

 printf '%s\n' "$latest_version"
}

if [ "$MODE" = "full" ] || [ "$MODE" = "cache-only" ]; then
 cache_args=()
 if [ "$CLEAN_BUILD" = "1" ]; then
   cache_args+=(--clean)
 fi
 /bin/bash "$SCRIPT_DIR/build-kernel-zfs-cache.sh" "${cache_args[@]}"
fi

[ -f "$WORKDIR/.kernel-version-current" ] || { echo "Missing cache metadata: $WORKDIR/.kernel-version-current" >&2; exit 1; }
[ -f "$WORKDIR/.kernel-release-current" ] || { echo "Missing cache metadata: $WORKDIR/.kernel-release-current" >&2; exit 1; }
[ -f "$WORKDIR/.kernel-src-dir-current" ] || { echo "Missing cache metadata: $WORKDIR/.kernel-src-dir-current" >&2; exit 1; }
[ -f "$WORKDIR/.kernel-staging-dir-current" ] || { echo "Missing cache metadata: $WORKDIR/.kernel-staging-dir-current" >&2; exit 1; }

KERNEL_VERSION="$(cat "$WORKDIR/.kernel-version-current")"
KERNEL_RELEASE="$(cat "$WORKDIR/.kernel-release-current")"
KERNEL_SRC_DIR="$(cat "$WORKDIR/.kernel-src-dir-current")"
KERNEL_STAGING_DIR="$(cat "$WORKDIR/.kernel-staging-dir-current")"
KERNEL_RELEASE_FILE="$WORKDIR/.kernel-release-$KERNEL_VERSION"
ZFS_TAG_CURRENT_FILE="$WORKDIR/.zfs-tag-current"

echo "Using kernel version: $KERNEL_VERSION"
echo "Using Ubuntu mirror: $UBUNTU_MIRROR"
echo "Using Ubuntu security mirror: $UBUNTU_SECURITY_MIRROR"
echo "Using install profile: $INSTALL_PROFILE"
echo "Clean build: $CLEAN_BUILD"

if [ "$MODE" = "cache-only" ]; then
 echo "cache-only mode complete: kernel and OpenZFS artifacts are prepared in $WORKDIR"
 exit 0
fi

if [ "$MODE" = "full" ]; then
 echo "Creating minimal rootfs..."

ROOTFS_PARENT="$(dirname "$ROOTFS")"
FREE_KB="$(df -Pk "$ROOTFS_PARENT" | awk 'NR==2 {print $4}')"
if [ -z "$FREE_KB" ] || [ "$FREE_KB" -lt "$ROOTFS_MIN_FREE_KB" ]; then
 echo "Insufficient free space for debootstrap at $ROOTFS_PARENT (have ${FREE_KB:-0} KB, need >= $ROOTFS_MIN_FREE_KB KB)." >&2
 exit 1
fi

if [ -e "$ROOTFS" ]; then
 echo "Removing existing rootfs at $ROOTFS before debootstrap..."
 for stale in "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/run"; do
  if mountpoint -q "$stale"; then
   sudo umount "$stale" || sudo umount -l "$stale" || true
  fi
 done
 sudo rm -rf "$ROOTFS"
fi

sudo debootstrap --variant=minbase "$UBUNTU_CODENAME" "$ROOTFS" "$UBUNTU_MIRROR"

bind_mount /dev "$ROOTFS/dev"
bind_mount /proc "$ROOTFS/proc"
bind_mount /sys "$ROOTFS/sys"
bind_mount /run "$ROOTFS/run"

sudo tee "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF' >/dev/null
#!/bin/sh
exit 101
EOF
sudo chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

sudo tee "$ROOTFS/etc/apt/sources.list" >/dev/null <<EOF
deb ${UBUNTU_MIRROR} ${UBUNTU_CODENAME} main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb ${UBUNTU_SECURITY_MIRROR} ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

sudo chroot "$ROOTFS" /bin/bash <<'EOF'
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y --no-install-recommends \
 bash \
 coreutils \
 ca-certificates \
 curl \
 dosfstools \
 fatresize \
 e2fsprogs \
 findutils \
 gawk \
 gdisk \
 grep \
 grub-common \
 grub-efi-amd64-bin \
 grub-pc-bin \
 iw \
 iproute2 \
 iputils-ping \
 network-manager \
 busybox \
 dialog \
 kmod \
 nano \
 parted \
 pciutils \
 php-cli \
 sed \
 udev \
 unzip \
 usbutils \
 util-linux \
 wpasupplicant \
 whiptail \
 wget

# Optional: include memtest when available in the configured Ubuntu release.
if apt-cache show memtest86+ >/dev/null 2>&1; then
 apt install -y --no-install-recommends memtest86+
fi

apt clean
rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/locale/*
rm -f /usr/sbin/policy-rc.d
EOF

unmount_rootfs_runtime_mounts
else
 echo "grub-iso mode: reusing existing kernel build, rootfs, and runtime assets"
 [ -d "$KERNEL_SRC_DIR" ] || { echo "Missing kernel source directory for grub-iso mode: $KERNEL_SRC_DIR" >&2; exit 1; }
 [ -d "$ROOTFS" ] || { echo "Missing rootfs for grub-iso mode: $ROOTFS" >&2; exit 1; }

 if [ -f "$KERNEL_RELEASE_FILE" ]; then
  KERNEL_RELEASE="$(cat "$KERNEL_RELEASE_FILE")"
 else
  cd "$KERNEL_SRC_DIR"
  KERNEL_RELEASE="$(make -s kernelrelease)"
  cd "$WORKDIR"
 fi

 if [ -f "$ZFS_TAG_CURRENT_FILE" ]; then
  echo "Reusing OpenZFS release tag: $(cat "$ZFS_TAG_CURRENT_FILE")"
 fi
fi

STAGED_KERNEL_IMAGE_PATH="$KERNEL_SRC_DIR/arch/x86/boot/bzImage"
STAGED_KERNEL_MODULES_PATH="$KERNEL_STAGING_DIR/lib/modules/$KERNEL_RELEASE"

[ -f "$STAGED_KERNEL_IMAGE_PATH" ] || { echo "Missing staged kernel image: $STAGED_KERNEL_IMAGE_PATH" >&2; exit 1; }
[ -d "$STAGED_KERNEL_MODULES_PATH" ] || { echo "Missing staged module tree: $STAGED_KERNEL_MODULES_PATH" >&2; exit 1; }
if ! find "$STAGED_KERNEL_MODULES_PATH" -type f \( -name 'zfs.ko' -o -name 'zfs.ko.xz' -o -name 'zfs.ko.zst' \) -print -quit | grep -q .; then
 echo "Missing staged ZFS module in $STAGED_KERNEL_MODULES_PATH" >&2
 exit 1
fi

sudo mkdir -p "$ROOTFS/mnt/persist" "$ROOTFS/boot" "$ONBOARDING_ASSET_DIR" "$ROOTFS/usr/local" "$ROOTFS/etc/rc.d"

# Avoid cross-profile leftovers when reusing rootfs (for example in grub-iso mode).
sudo rm -f \
   "$ONBOARDING_ASSET_DIR"/menu.sh \
   "$ONBOARDING_ASSET_DIR"/menu_*.sh \
   "$ONBOARDING_ASSET_DIR"/menu_gui_common.sh \
   "$ONBOARDING_ASSET_DIR"/create_internal_boot.sh \
   "$ONBOARDING_ASSET_DIR"/convert_internal_boot_to_dedicated.sh \
   "$ONBOARDING_ASSET_DIR"/create_flash_boot.sh \
   "$ONBOARDING_ASSET_DIR"/zip.sh \
   "$ONBOARDING_ASSET_DIR"/version_check.sh \
   "$ONBOARDING_ASSET_DIR"/installer-version \
   "$ONBOARDING_ASSET_DIR"/install-profile \
   "$ONBOARDING_ASSET_DIR"/menu-backend

[ -f "$SCRIPT_DIR/create_internal_boot_user.sh" ] || {
  echo "Missing required onboarding script: $SCRIPT_DIR/create_internal_boot_user.sh" >&2
  exit 1
}
[ -f "$SCRIPT_DIR/zip.sh" ] || {
  echo "Missing required onboarding script: $SCRIPT_DIR/zip.sh" >&2
  exit 1
}
[ -f "$SCRIPT_DIR/version_check.sh" ] || {
  echo "Missing required onboarding script: $SCRIPT_DIR/version_check.sh" >&2
  exit 1
}
[ -f "$SCRIPT_DIR/create_flash_boot.sh" ] || {
  echo "Missing required onboarding script: $SCRIPT_DIR/create_flash_boot.sh" >&2
  exit 1
}

if [ "$MENU_UI" = "gui" ]; then
   [ -f "$SCRIPT_DIR/menu_gui_user.sh" ] || {
    echo "Missing required onboarding script: $SCRIPT_DIR/menu_gui_user.sh" >&2
   exit 1
 }
    [ -f "$SCRIPT_DIR/menu_gui_common.sh" ] || {
      echo "Missing required onboarding script: $SCRIPT_DIR/menu_gui_common.sh" >&2
    exit 1
 }
    sudo cp "$SCRIPT_DIR/menu_gui_common.sh" "$ONBOARDING_ASSET_DIR/menu_gui_common.sh"
   sudo cp "$SCRIPT_DIR/menu_gui_user.sh" "$ONBOARDING_ASSET_DIR/menu_gui_user.sh"
    sudo chmod +x "$ONBOARDING_ASSET_DIR/menu_gui_common.sh"
   sudo chmod +x "$ONBOARDING_ASSET_DIR/menu_gui_user.sh"
fi

sudo cp "$SCRIPT_DIR/create_internal_boot_user.sh" "$ONBOARDING_ASSET_DIR/create_internal_boot.sh"
sudo cp "$SCRIPT_DIR/create_flash_boot.sh" "$ONBOARDING_ASSET_DIR/create_flash_boot.sh"
sudo cp "$SCRIPT_DIR/zip.sh" "$ONBOARDING_ASSET_DIR/zip.sh"
sudo cp "$SCRIPT_DIR/version_check.sh" "$ONBOARDING_ASSET_DIR/version_check.sh"
installer_version="$(read_lock_json_string "version" "$(cat "$REPO_ROOT/build/unraid-release-lock.json")")"
if [[ ! "$installer_version" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  echo "Invalid installer version in build/unraid-release-lock.json: $installer_version" >&2
  exit 1
fi
printf '%s\n' "$installer_version" | sudo tee "$ONBOARDING_ASSET_DIR/installer-version" >/dev/null
sudo cp "$SCRIPT_DIR/menu_gui_common.sh" "$ONBOARDING_ASSET_DIR/menu_gui_common.sh"
sudo cp "$SCRIPT_DIR/menu_gui_user.sh" "$ONBOARDING_ASSET_DIR/menu.sh"
sudo chmod +x "$ONBOARDING_ASSET_DIR/menu.sh" "$ONBOARDING_ASSET_DIR/menu_gui_common.sh" "$ONBOARDING_ASSET_DIR/create_internal_boot.sh" "$ONBOARDING_ASSET_DIR/create_flash_boot.sh" "$ONBOARDING_ASSET_DIR/zip.sh" "$ONBOARDING_ASSET_DIR/version_check.sh"

if [ -n "$MENU_BACKEND_DEFAULT" ]; then
   printf '%s\n' "$MENU_BACKEND_DEFAULT" | sudo tee "$ONBOARDING_ASSET_DIR/menu-backend" >/dev/null
   sudo chmod 0644 "$ONBOARDING_ASSET_DIR/menu-backend"
   echo "Using default menu backend: $MENU_BACKEND_DEFAULT"
fi

# Ensure legacy alternate menu/helpers are not present in user builds.
sudo rm -f "$ONBOARDING_ASSET_DIR/menu_user.sh" "$ONBOARDING_ASSET_DIR/menu_gui.sh"

# Assets are no longer required for either profile.
sudo rm -rf "$ONBOARDING_ASSET_DIR/assets"

[ -d "$UNGRUB_SRC" ] || {
 echo "Missing ungrub runtime assets: $UNGRUB_SRC" >&2
 exit 1
}
sudo rm -rf "$ROOTFS/usr/local/ungrub"
sudo cp -a "$UNGRUB_SRC" "$ROOTFS/usr/local/ungrub"
for ungrub_tool in mkbootable mkgrub mktheme update_grub_from_syslinux; do
 if [ -f "$ROOTFS/usr/local/ungrub/$ungrub_tool" ]; then
  sudo chmod +x "$ROOTFS/usr/local/ungrub/$ungrub_tool"
 fi
done

sudo tee "$ROOTFS/etc/rc.d/rc.runlog" <<'EOF' >/dev/null
#!/bin/sh
log() {
    printf '%s\n' "$*"
}
EOF
sudo chmod +x "$ROOTFS/etc/rc.d/rc.runlog"

sudo mkdir -p "$ROOTFS/usr/local/sbin"
sudo mkdir -p "$ROOTFS/usr/share/udhcpc"
sudo tee "$ROOTFS/usr/share/udhcpc/default.script" <<'EOF' >/dev/null
#!/bin/sh

RESOLV_CONF="/etc/resolv.conf"

mask_to_prefix() {
   local mask="$1" prefix=0 octet

   OLDIFS="$IFS"
   IFS=.
   set -- $mask
   IFS="$OLDIFS"

   for octet in "$@"; do
      case "$octet" in
         255) prefix=$((prefix + 8)) ;;
         254) prefix=$((prefix + 7)) ;;
         252) prefix=$((prefix + 6)) ;;
         248) prefix=$((prefix + 5)) ;;
         240) prefix=$((prefix + 4)) ;;
         224) prefix=$((prefix + 3)) ;;
         192) prefix=$((prefix + 2)) ;;
         128) prefix=$((prefix + 1)) ;;
         0) ;;
         *) return 1 ;;
      esac
   done

   printf '%s\n' "$prefix"
}

flush_interface() {
   ip addr flush dev "$interface" 2>/dev/null || true
   ip route flush dev "$interface" 2>/dev/null || true
}

case "$1" in
   deconfig)
      flush_interface
      ;;
   renew|bound)
      flush_interface
      ip link set "$interface" up || true

      prefix="$(mask_to_prefix "${subnet:-255.255.255.0}")"
      ip addr add "$ip/$prefix" dev "$interface"

      if [ -n "${router:-}" ]; then
         metric=0
         for gateway in $router; do
            ip route add default via "$gateway" dev "$interface" metric "$metric" 2>/dev/null || true
            metric=$((metric + 1))
         done
      fi

      : > "$RESOLV_CONF"
      if [ -n "${domain:-}" ]; then
         printf 'search %s\n' "$domain" >> "$RESOLV_CONF"
      fi
      for nameserver in $dns; do
         printf 'nameserver %s\n' "$nameserver" >> "$RESOLV_CONF"
      done
      ;;
esac

exit 0
EOF
sudo chmod +x "$ROOTFS/usr/share/udhcpc/default.script"
sudo tee "$ROOTFS/usr/local/sbin/udhcpc" <<'EOF' >/dev/null
#!/bin/sh
exec /bin/busybox udhcpc -s /usr/share/udhcpc/default.script "$@"
EOF
sudo chmod +x "$ROOTFS/usr/local/sbin/udhcpc"

sudo tee "$ROOTFS/usr/local/sbin/resize_persistence.sh" <<'EOF' >/dev/null
#!/bin/bash
set -euo pipefail

log() {
 printf '%s\n' "[resize-persist] $*"
}

on_error() {
 local line_no="$1"
 local cmd="$2"
 local rc="$3"
 log "error at line ${line_no}: ${cmd} (exit=${rc})"
 exit "$rc"
}

trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

find_persist_dev() {
 local link candidate resolved

 for link in \
   /dev/disk/by-partlabel/INSTALL-PERSIST \
   /dev/disk/by-partlabel/ONBOARDING-PERSIST \
   /dev/disk/by-label/INSTALL-PERSIST \
   /dev/disk/by-label/INSTALLPERS; do
    if [ -L "$link" ] || [ -e "$link" ]; then
      resolved=""
      if resolved="$(readlink -f -- "$link" 2>/dev/null)"; then
             if [ -n "$resolved" ] && [ -b "$resolved" ]; then
                  printf '%s\n' "$resolved"
                  return 0
             fi
      fi
   fi
 done

 candidate="$(blkid -L INSTALL-PERSIST 2>/dev/null || true)"
 if [ -n "$candidate" ] && [ -b "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
 fi
 candidate="$(blkid -L INSTALLPERS 2>/dev/null || true)"
 if [ -n "$candidate" ] && [ -b "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
 fi

 return 0
}

partition_parent_disk() {
 local part_dev="$1"
 local pkname=""

 pkname="$(lsblk -nro PKNAME "$part_dev" 2>/dev/null | head -n1 || true)"
 if [ -n "$pkname" ] && [ -b "/dev/$pkname" ]; then
   printf '%s\n' "/dev/$pkname"
   return 0
 fi

 case "$part_dev" in
   /dev/nvme*n*p[0-9]*|/dev/mmcblk*p[0-9]*) printf '%s\n' "${part_dev%p[0-9]*}" ;;
   /dev/sd[a-z][0-9]*|/dev/vd[a-z][0-9]*|/dev/xvd[a-z][0-9]*|/dev/hd[a-z][0-9]*) printf '%s\n' "${part_dev%[0-9]*}" ;;
   *) return 1 ;;
 esac
}

partition_number() {
 local part_dev="$1"
 local pn=""

 pn="$(lsblk -nro PARTN "$part_dev" 2>/dev/null | head -n1 || true)"
 if [ -n "$pn" ]; then
   printf '%s\n' "$pn"
   return 0
 fi

 case "$part_dev" in
   *p[0-9]*) printf '%s\n' "${part_dev##*p}" ;;
   *[0-9]) printf '%s\n' "${part_dev##*[!0-9]}" ;;
   *) return 1 ;;
 esac
}

refresh_partition_path() {
 local disk="$1"
 local pn="$2"
 if [ -b "${disk}p${pn}" ]; then
   printf '%s\n' "${disk}p${pn}"
 elif [ -b "${disk}${pn}" ]; then
   printf '%s\n' "${disk}${pn}"
 else
   return 1
 fi
}

normalize_vfat_label() {
 local raw_label="$1"
 local normalized_label=""

 normalized_label="$(printf '%s' "$raw_label" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9' | cut -c1-11)"
 if [ -z "$normalized_label" ]; then
    normalized_label="INSTALLPERS"
 fi

 printf '%s\n' "$normalized_label"
}

copy_tree_with_progress() {
 local src_root="$1"
 local dst_root="$2"
 local phase="$3"
 local total=""
 local done_count=0
 local pct=0
 local last_pct=-1
 local item=""
 local rel=""
 local target_dir=""
 local item_list_file=""

 total="$(find "$src_root" -mindepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]')"
 if [ -z "$total" ] || [ "$total" -eq 0 ] 2>/dev/null; then
   log "${phase}: 100% (nothing to copy)"
   return 0
 fi

 log "${phase}: 0% (0/${total})"

 item_list_file="$(mktemp /tmp/persist-copy-list.XXXXXX)"
 find "$src_root" -mindepth 1 -print0 > "$item_list_file"

 while IFS= read -r -d '' item; do
   rel="${item#"$src_root"/}"
   if [ "$rel" = "$item" ]; then
      continue
   fi

   if [ -d "$item" ]; then
      mkdir -p "$dst_root/$rel"
   else
      target_dir="$(dirname "$dst_root/$rel")"
      mkdir -p "$target_dir"
      cp -a "$item" "$dst_root/$rel"
   fi

   done_count=$((done_count + 1))
   pct=$((done_count * 100 / total))
   if [ "$pct" -ne "$last_pct" ] && { [ "$pct" -eq 100 ] || [ $((pct % 5)) -eq 0 ]; }; then
      log "${phase}: ${pct}% (${done_count}/${total})"
      last_pct="$pct"
   fi
 done < "$item_list_file"

 rm -f "$item_list_file"

 if [ "$last_pct" -ne 100 ]; then
   log "${phase}: 100% (${done_count}/${total})"
 fi
}

recreate_vfat_from_backup() {
 local persist_dev="$1"
 local vfat_label=""
 local backup_dir=""
 local src_mount=""
 local dst_mount=""

 vfat_label="$(blkid -o value -s LABEL "$persist_dev" 2>/dev/null || true)"
 vfat_label="$(normalize_vfat_label "$vfat_label")"
 log "vfat label resolved to ${vfat_label}"

 backup_dir="$(mktemp -d /tmp/persist-vfat-backup.XXXXXX)"
 src_mount="$(mktemp -d /tmp/persist-vfat-src.XXXXXX)"
 dst_mount="$(mktemp -d /tmp/persist-vfat-dst.XXXXXX)"
 log "created temporary working directories"

 if ! mount -t vfat "$persist_dev" "$src_mount" >/dev/null 2>&1; then
    log "unable to mount existing vfat persistence for backup; aborting to avoid data loss"
    rmdir "$src_mount" "$dst_mount" >/dev/null 2>&1 || true
    rm -rf "$backup_dir"
    return 1
 fi

 log "backing up vfat persistence content"
 copy_tree_with_progress "$src_mount" "$backup_dir" "backup"
 sync || true
 umount "$src_mount"

 log "recreating vfat filesystem"

 mkfs.vfat -F 32 -n "$vfat_label" "$persist_dev" >/dev/null

 log "restoring backup content"
 mount -t vfat "$persist_dev" "$dst_mount"
 copy_tree_with_progress "$backup_dir" "$dst_mount" "restore"
 sync || true
 umount "$dst_mount"

 log "vfat backup/restore completed"

 rmdir "$src_mount" "$dst_mount" >/dev/null 2>&1 || true
 rm -rf "$backup_dir"
 return 0
}

main() {
 local persist_dev=""
 local boot_disk=""
 local part_no=""
 local fstype=""
 local mounted_targets=""

 persist_dev="$(find_persist_dev)"
 if [ -z "$persist_dev" ] || [ ! -b "$persist_dev" ]; then
   log "persistence partition not found"
   exit 1
 fi

 mounted_targets="$(findmnt -rn -S "$persist_dev" -o TARGET 2>/dev/null || true)"
 if [ -n "$mounted_targets" ]; then
   log "unmounting persistence before resize"
   while IFS= read -r target; do
    [ -n "$target" ] || continue
    umount "$target"
   done <<< "$mounted_targets"
 fi

 boot_disk="$(partition_parent_disk "$persist_dev")"
 part_no="$(partition_number "$persist_dev")"
 if [ -z "$boot_disk" ] || [ -z "$part_no" ]; then
   log "failed to determine parent disk/partition number"
   exit 1
 fi

 log "resizing partition ${persist_dev} (disk=${boot_disk} part=${part_no})"
 parted -s -f "$boot_disk" unit s resizepart "$part_no" 100%
 log "partition geometry updated"
 partprobe "$boot_disk" >/dev/null 2>&1 || true
 udevadm settle --timeout=8 >/dev/null 2>&1 || true

 persist_dev="$(refresh_partition_path "$boot_disk" "$part_no")"
 fstype="$(blkid -o value -s TYPE "$persist_dev" 2>/dev/null || true)"

 case "$fstype" in
   ext4)
      log "resizing ext4 filesystem"
    resize2fs "$persist_dev"
    ;;
   vfat)
      log "resizing vfat filesystem via backup/recreate/restore"
    if command -v fsck.vfat >/dev/null 2>&1; then
      fsck.vfat -a "$persist_dev" >/dev/null 2>&1 || true
    elif command -v dosfsck >/dev/null 2>&1; then
      dosfsck -a "$persist_dev" >/dev/null 2>&1 || true
    fi

      recreate_vfat_from_backup "$persist_dev"
    ;;
   *)
    log "unsupported persistence filesystem: ${fstype:-unknown}"
    exit 1
    ;;
 esac

 if [ -d /mnt/persist ]; then
   mount "$persist_dev" /mnt/persist >/dev/null 2>&1 || true
 fi

 log "resize complete (${persist_dev}, fs=${fstype:-unknown})"
}

main "$@"
EOF
sudo chmod +x "$ROOTFS/usr/local/sbin/resize_persistence.sh"

printf '%s\n' "$STATIC_HOSTNAME" | sudo tee "$ROOTFS/etc/hostname" >/dev/null
cat <<EOF | sudo tee "$ROOTFS/etc/hosts" >/dev/null
127.0.0.1 localhost
127.0.1.1 ${STATIC_HOSTNAME}

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
cat <<EOF | sudo tee "$ROOTFS/etc/machine-info" >/dev/null
PRETTY_HOSTNAME="${PRETTY_HOSTNAME}"
EOF
printf '%s\n' "$PRETTY_HOSTNAME" | sudo tee "$ROOTFS/etc/issue" >/dev/null

if [ -d "$ZFS_USERSPACE_STAGING_DIR" ]; then
 echo "Installing staged OpenZFS userspace into rootfs..."
 (cd "$ZFS_USERSPACE_STAGING_DIR" && tar -cf - .) | sudo tar -xf - -C "$ROOTFS" --keep-directory-symlink
elif [ -d "$ZFS_SRC_DIR" ]; then
 echo "OpenZFS userspace staging not found; falling back to source install into rootfs..."
 cd "$ZFS_SRC_DIR"
 sudo make install DESTDIR="$ROOTFS"
 cd "$WORKDIR"

 sudo mkdir -p "$ROOTFS/etc/ld.so.conf.d"
 cat <<'EOF' | sudo tee "$ROOTFS/etc/ld.so.conf.d/local-zfs.conf" >/dev/null
/usr/local/lib
/usr/local/lib64
EOF
 if [ -x "$ROOTFS/sbin/ldconfig" ]; then
  sudo chroot "$ROOTFS" /sbin/ldconfig
 elif [ -x "$ROOTFS/usr/sbin/ldconfig" ]; then
  sudo chroot "$ROOTFS" /usr/sbin/ldconfig
 fi
fi

if [ -d "$ZFS_USERSPACE_STAGING_DIR" ]; then
 sudo mkdir -p "$ROOTFS/etc/ld.so.conf.d"
 cat <<'EOF' | sudo tee "$ROOTFS/etc/ld.so.conf.d/local-zfs.conf" >/dev/null
/usr/local/lib
/usr/local/lib64
EOF
 if [ -x "$ROOTFS/sbin/ldconfig" ]; then
  sudo chroot "$ROOTFS" /sbin/ldconfig
 elif [ -x "$ROOTFS/usr/sbin/ldconfig" ]; then
  sudo chroot "$ROOTFS" /usr/sbin/ldconfig
 fi
fi

echo "Preparing ISO..."

rm -rf "$ISO"
mkdir -p "$ISO/boot/grub"
[ -d "$UNGRUB_THEME_SRC" ] || { echo "Missing theme assets: $UNGRUB_THEME_SRC" >&2; exit 1; }
mkdir -p "$ISO_THEME_DIR"
cp -a "$UNGRUB_THEME_SRC/." "$ISO_THEME_DIR/"

cp "$STAGED_KERNEL_IMAGE_PATH" "$ISO/boot/vmlinuz"

# Include memtest EFI payload when present so GRUB can expose a menu option.
MEMTEST_X64_SOURCE=""
MEMTEST_IA32_SOURCE=""
for memtest_candidate in "$ROOTFS/boot/memtest86+x64.efi" "$ROOTFS/boot/memtest86+ia32.efi"; do
 if [ -f "$memtest_candidate" ]; then
  cp "$memtest_candidate" "$ISO/boot/"
   case "$(basename "$memtest_candidate")" in
    memtest86+x64.efi)
      MEMTEST_X64_SOURCE="$memtest_candidate"
      ;;
    memtest86+ia32.efi)
      MEMTEST_IA32_SOURCE="$memtest_candidate"
      ;;
   esac
 fi
done

sudo mkdir -p "$ROOTFS/lib/modules"
sudo rm -rf "$ROOTFS/lib/modules/$KERNEL_RELEASE"
sudo cp -a "$STAGED_KERNEL_MODULES_PATH" "$ROOTFS/lib/modules/"
sudo depmod -a -b "$ROOTFS" "$KERNEL_RELEASE"

sudo tee "$ROOTFS/init" <<'EOF' >/dev/null
#!/bin/bash

printf 'Loading......\n' > /dev/console 2>/dev/null || printf 'Loading......\n'

boot_log() {
 local message="$*"
 local line=""

 line="[init] ${message}"

 # Keep init diagnostics in kernel log only to avoid noisy console output.
 if [ -w /dev/kmsg ]; then
    printf '<6>[init] %s\n' "$message" > /dev/kmsg
 fi

 if [ -n "${BOOT_LOG_FILE:-}" ]; then
    mkdir -p "${BOOT_LOG_DIR}" 2>/dev/null || true
    printf '%s\n' "$line" >> "${BOOT_LOG_FILE}" 2>/dev/null || true
 fi

 if [ -n "${BOOT_LOG_PERSIST_FILE:-}" ]; then
    mkdir -p "${BOOT_LOG_PERSIST_DIR}" 2>/dev/null || true
    printf '%s\n' "$line" >> "${BOOT_LOG_PERSIST_FILE}" 2>/dev/null || true
 fi
}

status_msg() {
 local message="$*"
 boot_log "$message"
 if [ -w /dev/tty0 ]; then
    printf '[init] %s\n' "$message" > /dev/tty0 2>/dev/null || true
 fi
}

init_boot_log_files() {
 BOOT_LOG_DIR="/run/logs"
 BOOT_LOG_FILE="${BOOT_LOG_DIR}/boot.log"
 BOOT_LOG_LINK_DIR="/var/logs"
 BOOT_LOG_LINK_FILE="${BOOT_LOG_LINK_DIR}/boot.log"

 mkdir -p "$BOOT_LOG_DIR" 2>/dev/null || true
 touch "$BOOT_LOG_FILE" 2>/dev/null || true

 mkdir -p "$BOOT_LOG_LINK_DIR" 2>/dev/null || true
 ln -sf "$BOOT_LOG_FILE" "$BOOT_LOG_LINK_FILE" 2>/dev/null || true
}

BOOT_LOG_DIR=""
BOOT_LOG_FILE=""
BOOT_LOG_PERSIST_DIR=""
BOOT_LOG_PERSIST_FILE=""

boot_log "init started"

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mkdir -p /run
mount -t tmpfs tmpfs /run
mkdir -p /tmp
mount -t tmpfs tmpfs /tmp

init_boot_log_files
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/lib64:${LD_LIBRARY_PATH:-}

boot_log "runtime filesystems mounted"

STATIC_HOSTNAME="internal-boot-setup"
PRETTY_HOSTNAME="Internal Boot Setup"

if [ -w /proc/sys/kernel/hostname ]; then
 printf '%s\n' "$PRETTY_HOSTNAME" > /proc/sys/kernel/hostname 2>/dev/null \
    || printf '%s\n' "$STATIC_HOSTNAME" > /proc/sys/kernel/hostname 2>/dev/null \
    || true
elif command -v hostname >/dev/null 2>&1; then
 hostname "$PRETTY_HOSTNAME" 2>/dev/null || hostname "$STATIC_HOSTNAME" 2>/dev/null || true
fi

boot_log "hostname configured"

load_vm_display_modules() {
 local module_name

 for module_name in qxl virtio_gpu bochs_drm cirrus simpledrm; do
    modprobe "$module_name" 2>/dev/null || true
 done
}

load_vm_display_modules
boot_log "display modules probed"

load_storage_modules() {
 local module_name

 for module_name in usb_storage uas sd_mod sr_mod ahci pcieport pciehp vmd nvme_core nvme nvme_tcp nvme_fabrics virtio_blk virtio_scsi vfat exfat ext4 xfs ntfs3; do
    modprobe "$module_name" 2>/dev/null || true
 done
}

load_storage_modules_from_modalias() {
 local alias_file
 for alias_file in /sys/bus/pci/devices/*/modalias; do
    [ -r "$alias_file" ] || continue
    modprobe -ab "$(cat "$alias_file")" 2>/dev/null || true
 done
}

load_storage_modules
load_storage_modules_from_modalias
if [ -w /sys/bus/pci/rescan ]; then
 echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
fi
boot_log "storage modules probed"

load_nic_modules_from_modalias() {
 local alias_file
 for alias_file in /sys/bus/pci/devices/*/modalias /sys/bus/usb/devices/*/modalias; do
    [ -r "$alias_file" ] || continue
    modprobe -ab "$(cat "$alias_file")" 2>/dev/null || true
 done
}

start_device_discovery() {
 if command -v udevd >/dev/null 2>&1; then
    udevd --daemon >/dev/null 2>&1 || true
 elif command -v systemd-udevd >/dev/null 2>&1; then
    systemd-udevd --daemon >/dev/null 2>&1 || true
 elif [ -x /lib/systemd/systemd-udevd ]; then
    /lib/systemd/systemd-udevd --daemon >/dev/null 2>&1 || true
 elif [ -x /usr/lib/systemd/systemd-udevd ]; then
    /usr/lib/systemd/systemd-udevd --daemon >/dev/null 2>&1 || true
 elif [ -x /usr/lib/udev/udevd ]; then
    /usr/lib/udev/udevd --daemon >/dev/null 2>&1 || true
 fi

 if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload >/dev/null 2>&1 || true
    udevadm trigger --type=subsystems --action=add >/dev/null 2>&1 || true
    udevadm trigger --type=devices --action=add >/dev/null 2>&1 || true
   boot_log "waiting for udev settle (startup)"
   if ! udevadm settle --timeout=10 >/dev/null 2>&1; then
      boot_log "warning: udev settle timed out during startup"
   else
      boot_log "udev settle complete (startup)"
   fi
 fi
}

list_candidate_ifaces() {
 local iface
 for iface in /sys/class/net/*; do
    [ -e "$iface" ] || continue
    iface="${iface##*/}"
    case "$iface" in
     lo|sit*|ip6tnl*|tunl*|dummy*|bonding_masters)
        continue
        ;;
    esac
    echo "$iface"
 done
}

run_dhcp() {
 local iface="$1"
 if command -v dhclient >/dev/null 2>&1; then
    dhclient -4 -1 -v "$iface" >/dev/null 2>&1 && return 0
 fi
 if command -v udhcpc >/dev/null 2>&1; then
    udhcpc -n -q -i "$iface" >/dev/null 2>&1 && return 0
 fi
 return 1
}

boot_log "starting device discovery"
start_device_discovery
if [ "$(list_candidate_ifaces | wc -l)" -eq 0 ]; then
 load_nic_modules_from_modalias
 boot_log "NIC modules loaded from modalias"
 start_device_discovery
fi

boot_log "probing network interfaces"
for iface in $(list_candidate_ifaces); do
 ip link set "$iface" up || true
 if run_dhcp "$iface"; then
    if ip -4 -o addr show dev "$iface" scope global | grep -q .; then
     boot_log "network ready on $iface"
     break
    fi
 fi
done

boot_log "checking persistence device"

if [ -d /dev/disk ]; then
 boot_log "/dev/disk present"
else
 boot_log "warning: /dev/disk missing"
fi

if [ -d /dev/disk/by-label ]; then
 boot_log "/dev/disk/by-label present"
else
 boot_log "warning: /dev/disk/by-label missing"
fi

if [ -d /dev/disk/by-partlabel ]; then
 boot_log "/dev/disk/by-partlabel present"
else
 boot_log "warning: /dev/disk/by-partlabel missing"
fi

mkdir -p /mnt/persist
PERSISTENT_ROOT=""
PERSISTENT_ZIP_DIR=""
PERSIST_READY=0
PERSIST_LABEL_DEFAULT="INSTALL-PERSIST"
PERSIST_PARTLABEL_DEFAULT="INSTALL-PERSIST"
PERSIST_PARTLABEL_LEGACY="ONBOARDING-PERSIST"
PERSIST_LABEL="$PERSIST_LABEL_DEFAULT"
PERSIST_PARTLABEL="$PERSIST_PARTLABEL_DEFAULT"
PERSIST_DEV=""
PERSIST_FS="ext4"
PERSIST_AUTOCREATE="0"
PERSIST_AUTOEXPAND="1"
PERSIST_DISABLED="0"

for cmdarg in $(cat /proc/cmdline 2>/dev/null); do
 case "$cmdarg" in
  persist_label=*)
    PERSIST_LABEL="${cmdarg#persist_label=}"
    ;;
  persist_partlabel=*)
    PERSIST_PARTLABEL="${cmdarg#persist_partlabel=}"
    ;;
  persist_dev=*)
    PERSIST_DEV="${cmdarg#persist_dev=}"
    ;;
   persist_fs=*)
      PERSIST_FS="${cmdarg#persist_fs=}"
      ;;
   persist_autocreate=*)
      PERSIST_AUTOCREATE="${cmdarg#persist_autocreate=}"
      ;;
   persist_autocreate)
      PERSIST_AUTOCREATE="1"
      ;;
   persist_autoexpand=*)
      PERSIST_AUTOEXPAND="${cmdarg#persist_autoexpand=}"
      ;;
   persist_autoexpand)
      PERSIST_AUTOEXPAND="1"
      ;;
   persist_disable=*)
      PERSIST_DISABLED="${cmdarg#persist_disable=}"
      ;;
   persist_disable)
      PERSIST_DISABLED="1"
      ;;
 esac
done

if [ -z "$PERSIST_PARTLABEL" ]; then
 PERSIST_PARTLABEL="$PERSIST_PARTLABEL_DEFAULT"
fi

case "$PERSIST_AUTOCREATE" in
   1|true|yes|on) PERSIST_AUTOCREATE="1" ;;
   *) PERSIST_AUTOCREATE="0" ;;
esac

case "$PERSIST_AUTOEXPAND" in
   1|true|yes|on) PERSIST_AUTOEXPAND="1" ;;
   *) PERSIST_AUTOEXPAND="0" ;;
esac

case "$PERSIST_DISABLED" in
   1|true|yes|on) PERSIST_DISABLED="1" ;;
   *) PERSIST_DISABLED="0" ;;
esac

case "${PERSIST_FS,,}" in
   ext4|fat32|vfat)
      PERSIST_FS="${PERSIST_FS,,}"
      ;;
   *)
      boot_log "invalid persist_fs='$PERSIST_FS'; defaulting to ext4"
      PERSIST_FS="ext4"
      ;;
esac

   vfat_label_from() {
    local raw_label="$1"
    local normalized_label=""

    normalized_label="$(printf '%s' "$raw_label" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9' | cut -c1-11)"
    if [ -z "$normalized_label" ]; then
       normalized_label="INSTALLPERS"
    fi

    printf '%s\n' "$normalized_label"
   }

   PERSIST_LABEL_VFAT="$(vfat_label_from "$PERSIST_LABEL")"

   boot_log "persistence selectors: label=$PERSIST_LABEL label_vfat=$PERSIST_LABEL_VFAT partlabel=$PERSIST_PARTLABEL${PERSIST_DEV:+ dev=$PERSIST_DEV} fs=$PERSIST_FS autocreate=$PERSIST_AUTOCREATE autoexpand=$PERSIST_AUTOEXPAND disabled=$PERSIST_DISABLED"

find_persist_devices() {
 local link_path candidate dev_name dev_path dev_partlabel dev_label blkid_line

 if [ -n "$PERSIST_DEV" ]; then
    if [ -b "$PERSIST_DEV" ]; then
        printf '%s\n' "$PERSIST_DEV"
    fi
 fi

 for link_path in \
    "/dev/disk/by-label/$PERSIST_LABEL" \
    "/dev/disk/by-label/$PERSIST_LABEL_VFAT" \
    "/dev/disk/by-partlabel/$PERSIST_PARTLABEL" \
    "/dev/disk/by-partlabel/$PERSIST_PARTLABEL_LEGACY"; do
    if [ -e "$link_path" ]; then
        readlink -f "$link_path" 2>/dev/null || true
    fi
 done

 candidate="$(blkid -L "$PERSIST_LABEL" 2>/dev/null || true)"
 if [ -n "$candidate" ]; then
    printf '%s\n' "$candidate"
 fi

 if [ "$PERSIST_LABEL_VFAT" != "$PERSIST_LABEL" ]; then
    candidate="$(blkid -L "$PERSIST_LABEL_VFAT" 2>/dev/null || true)"
    if [ -n "$candidate" ]; then
       printf '%s\n' "$candidate"
    fi
 fi

 blkid 2>/dev/null | awk -F: -v lbl="$PERSIST_LABEL" -v lblv="$PERSIST_LABEL_VFAT" -v plbl="$PERSIST_PARTLABEL" -v lplbl="$PERSIST_PARTLABEL_LEGACY" '
    index($0, "LABEL=\"" lbl "\"") || index($0, "LABEL=\"" lblv "\"") || index($0, "PARTLABEL=\"" plbl "\"") || index($0, "PARTLABEL=\"" lplbl "\"") {print $1}
 ' || true

 if command -v lsblk >/dev/null 2>&1; then
    for dev_name in $(lsblk -nrdo NAME 2>/dev/null || true); do
         [ -n "$dev_name" ] || continue
         dev_path="/dev/$dev_name"
         [ -b "$dev_path" ] || continue

         case "$dev_name" in
            loop*|ram*|fd*|sr*|md*|dm-*)
               continue
               ;;
         esac

         case "$dev_name" in
            vd[a-z]|sd[a-z]|xvd[a-z]|hd[a-z]|nvme*n[0-9]|mmcblk[0-9])
               continue
               ;;
         esac

         case "$dev_name" in
            *[0-9]|*p[0-9])
               ;;
            *)
               continue
               ;;
         esac

         dev_partlabel="$(lsblk -nro PARTLABEL "$dev_path" 2>/dev/null | head -n1 || true)"
         dev_label="$(lsblk -nro LABEL "$dev_path" 2>/dev/null | head -n1 || true)"

         if [ "$dev_partlabel" = "$PERSIST_PARTLABEL" ] || [ "$dev_partlabel" = "$PERSIST_PARTLABEL_LEGACY" ] || [ "$dev_label" = "$PERSIST_LABEL" ] || [ "$dev_label" = "$PERSIST_LABEL_VFAT" ]; then
            printf '%s\n' "$dev_path"
         fi
      done
 fi

 for dev_path in /dev/vd* /dev/sd* /dev/xvd* /dev/nvme*n*p* /dev/mmcblk*p*; do
      [ -b "$dev_path" ] || continue

      case "$dev_path" in
         /dev/vd[a-z]|/dev/sd[a-z]|/dev/xvd[a-z]|/dev/nvme*n[0-9]|/dev/mmcblk[0-9])
            continue
            ;;
      esac

      blkid_line="$(blkid "$dev_path" 2>/dev/null || true)"
      [ -n "$blkid_line" ] || continue

      case "$blkid_line" in
         *"LABEL=\"$PERSIST_LABEL\""*|*"LABEL=\"$PERSIST_LABEL_VFAT\""*|*"PARTLABEL=\"$PERSIST_PARTLABEL\""*|*"PARTLABEL=\"$PERSIST_PARTLABEL_LEGACY\""*)
            printf '%s\n' "$dev_path"
            ;;
      esac
 done

 # Last-resort fallback for media that has no labels yet: scan all partition numbers.
 # Intentionally exclude vfat so we do not accidentally mount the ISO EFI partition.
 for dev_path in /dev/vd[a-z][0-9]* /dev/sd[a-z][0-9]* /dev/xvd[a-z][0-9]* /dev/nvme*n*p[0-9]* /dev/mmcblk*p[0-9]*; do
      local fallback_fstype=""
      [ -b "$dev_path" ] || continue

      fallback_fstype="$(blkid -o value -s TYPE "$dev_path" 2>/dev/null || true)"
      case "$fallback_fstype" in
    exfat|ext4|xfs|ntfs|ntfs3)
            printf '%s\n' "$dev_path"
            ;;
      esac
 done
}

mount_persist_volume() {
 local persist_dev="$1"
 local persist_fstype=""
 local mount_err_file="/tmp/persist-mount.err"

 persist_fstype="$(blkid -o value -s TYPE "$persist_dev" 2>/dev/null || true)"
 boot_log "trying persistence device: $persist_dev${persist_fstype:+ ($persist_fstype)}"
 rm -f "$mount_err_file"

 if [ -n "$persist_fstype" ]; then
    mount -t "$persist_fstype" "$persist_dev" /mnt/persist 2>"$mount_err_file" && return 0
 fi

 mount "$persist_dev" /mnt/persist 2>"$mount_err_file" && return 0
 if [ -s "$mount_err_file" ]; then
    boot_log "mount failed on $persist_dev: $(head -n1 "$mount_err_file")"
 fi
 return 1
}

partition_path() {
 local disk="$1"
 local number="$2"

 if [ -b "${disk}p${number}" ]; then
    printf '%s\n' "${disk}p${number}"
    return 0
 fi

 if [ -b "${disk}${number}" ]; then
    printf '%s\n' "${disk}${number}"
    return 0
 fi

 return 1
}

boot_disk_from_onboarding_label() {
 local boot_part=""
 local boot_disk=""
 local dev_path=""

 if [ -e /dev/disk/by-label/INSTALLER ]; then
    boot_part="$(readlink -f /dev/disk/by-label/INSTALLER 2>/dev/null || true)"
 fi

 if [ -z "$boot_part" ] && [ -e /dev/disk/by-label/ONBOARDING ]; then
    boot_part="$(readlink -f /dev/disk/by-label/ONBOARDING 2>/dev/null || true)"
 fi

 if [ -z "$boot_part" ] && command -v blkid >/dev/null 2>&1; then
    boot_part="$(blkid -L INSTALLER 2>/dev/null || true)"
 fi

 if [ -z "$boot_part" ] && command -v blkid >/dev/null 2>&1; then
    boot_part="$(blkid -L ONBOARDING 2>/dev/null || true)"
 fi

 if [ -z "$boot_part" ] && command -v blkid >/dev/null 2>&1; then
    boot_part="$(blkid 2>/dev/null | awk -F: 'index($0, "LABEL=\"INSTALLER\"") {print $1; exit}')"
 fi

 if [ -z "$boot_part" ] && command -v blkid >/dev/null 2>&1; then
    boot_part="$(blkid 2>/dev/null | awk -F: 'index($0, "LABEL=\"ONBOARDING\"") {print $1; exit}')"
 fi

 if [ -z "$boot_part" ] && command -v blkid >/dev/null 2>&1; then
    for dev_path in /dev/sd? /dev/vd? /dev/xvd? /dev/hd? /dev/nvme*n[0-9] /dev/mmcblk[0-9]; do
      [ -b "$dev_path" ] || continue
      if blkid "$dev_path" 2>/dev/null | grep -q 'TYPE="iso9660"'; then
        boot_part="$dev_path"
        break
      fi
    done
 fi

 case "$boot_part" in
      /dev/sd[a-z]|/dev/vd[a-z]|/dev/xvd[a-z]|/dev/hd[a-z]|/dev/nvme*n[0-9]|/dev/mmcblk[0-9])
         boot_disk="$boot_part"
         ;;
    /dev/nvme*n*p[0-9]*|/dev/mmcblk*p[0-9]*)
      boot_disk="${boot_part%p[0-9]*}"
      ;;
    /dev/sd[a-z][0-9]*|/dev/vd[a-z][0-9]*|/dev/xvd[a-z][0-9]*|/dev/hd[a-z][0-9]*)
      boot_disk="${boot_part%[0-9]*}"
      ;;
    *)
      boot_disk=""
      ;;
 esac

 if [ -n "$boot_disk" ] && [ -b "$boot_disk" ]; then
    printf '%s\n' "$boot_disk"
 fi
}

create_persistence_partition_if_missing() {
 local boot_disk=""
 local p1=""
 local p2=""
 local persist_part=""
 local p1_end=""
 local p1_start=""
 local p1_sectors=""
 local start_sector=""
 local start_sector_default=""
 local disk_last_sector=""
 local target_part_no=""
 local mkpart_ok=0
 local parted_can_write=1
 local create_err_file="/tmp/persist-create.err"
 local mbr_prefix_backup="/tmp/persist-mbr-prefix.bin"
 local mbr_saved=0
 local parted_fstype_arg=""
 local sgdisk_typecode="8300"

 boot_disk="$(boot_disk_from_onboarding_label)"
 if [ -z "$boot_disk" ]; then
   boot_log "persistence create skipped: could not determine boot disk from INSTALLER/ONBOARDING media"
    return 1
 fi

 p1="$(partition_path "$boot_disk" 1 2>/dev/null || true)"
 p2="$(partition_path "$boot_disk" 2 2>/dev/null || true)"
 if [ -n "$p2" ] && [ -b "$p2" ]; then
    boot_log "persistence create skipped: partition 2 already present on $boot_disk"
    return 1
 fi

 case "$PERSIST_FS" in
   ext4)
      if ! command -v mkfs.ext4 >/dev/null 2>&1; then
         boot_log "mkfs.ext4 unavailable; cannot auto-create persistence"
         return 1
      fi
      ;;
   fat32|vfat)
      if ! command -v mkfs.vfat >/dev/null 2>&1; then
         boot_log "mkfs.vfat unavailable; cannot auto-create persistence"
         return 1
      fi
      parted_fstype_arg="fat32"
      sgdisk_typecode="0700"
      ;;
 esac

 start_sector_default=$((2048 * 1024 * 1024 / 512))

 if [ -n "$p1" ] && [ -b "$p1" ]; then
    target_part_no="2"
    p1_start="$(lsblk -nrdo START "$p1" 2>/dev/null | head -n1 || true)"
    p1_sectors="$(lsblk -nrdo SECTORS "$p1" 2>/dev/null | head -n1 || true)"
    if [ -n "$p1_start" ] && [ -n "$p1_sectors" ] && [ "$p1_sectors" -gt 0 ] 2>/dev/null; then
      p1_end=$((p1_start + p1_sectors - 1))
      start_sector=$((p1_end + 1))
    else
      start_sector="$start_sector_default"
      boot_log "warning: unable to read partition 1 geometry; using default start sector $start_sector"
    fi
 else
    target_part_no="1"
    start_sector="$start_sector_default"
 fi

 disk_last_sector="$(blockdev --getsz "$boot_disk" 2>/dev/null || true)"
 if [ -z "$disk_last_sector" ]; then
    boot_log "persistence create failed: unable to read disk size for $boot_disk"
    return 1
 fi

 if [ "$start_sector" -ge "$disk_last_sector" ]; then
    boot_log "persistence create failed: start sector $start_sector beyond disk end $disk_last_sector"
    return 1
 fi

 status_msg "creating persistent storage on $boot_disk (partition ${target_part_no})"
 rm -f "$create_err_file"

 # Preserve MBR bootstrap bytes (0-445). Some partitioning tools can replace them,
 # which can break BIOS boot on isohybrid media.
 if command -v dd >/dev/null 2>&1; then
      if dd if="$boot_disk" of="$mbr_prefix_backup" bs=1 count=446 status=none 2>/dev/null; then
         mbr_saved=1
         boot_log "saved MBR bootstrap bytes from $boot_disk"
      else
         boot_log "warning: unable to back up MBR bootstrap bytes from $boot_disk"
      fi
 fi

 if command -v parted >/dev/null 2>&1; then
    if ! parted -s "$boot_disk" unit s print >/dev/null 2>&1; then
      parted_can_write=0
      boot_log "parted skipped: unreadable disk label on $boot_disk"
    fi
 fi

 if command -v parted >/dev/null 2>&1 && [ "$parted_can_write" -eq 1 ]; then
    if parted -s "$boot_disk" unit s mkpart primary ${parted_fstype_arg:+$parted_fstype_arg }"${start_sector}s" 100% >/dev/null 2>"$create_err_file"; then
      mkpart_ok=1
      parted -s "$boot_disk" name "$target_part_no" "$PERSIST_PARTLABEL" >/dev/null 2>&1 || true
         case "$PERSIST_FS" in
             fat32|vfat)
                  parted -s "$boot_disk" set "$target_part_no" msftdata on >/dev/null 2>&1 || true
                  ;;
         esac
    else
      boot_log "warning: parted mkpart failed on $boot_disk (part ${target_part_no})"
      if [ -s "$create_err_file" ]; then
        boot_log "parted error: $(head -n1 "$create_err_file")"
      fi
    fi
 elif ! command -v parted >/dev/null 2>&1; then
    boot_log "warning: parted unavailable in init; trying sgdisk fallback"
 fi

 if [ "$mkpart_ok" -ne 1 ] && command -v sgdisk >/dev/null 2>&1; then
      sgdisk -e -g "$boot_disk" >/dev/null 2>"$create_err_file" || true
         if sgdisk -n "${target_part_no}:${start_sector}:0" -t "${target_part_no}:${sgdisk_typecode}" -c "${target_part_no}:${PERSIST_PARTLABEL}" "$boot_disk" >/dev/null 2>"$create_err_file"; then
      mkpart_ok=1
    else
      boot_log "warning: sgdisk partition create failed on $boot_disk (part ${target_part_no})"
         if [ -s "$create_err_file" ]; then
            boot_log "sgdisk error: $(head -n1 "$create_err_file")"
         fi
    fi
 fi

 if [ "$mkpart_ok" -ne 1 ] && command -v sfdisk >/dev/null 2>&1; then
      # sfdisk append fallback for environments where parted/sgdisk are absent or fail.
      if printf '%s\n' "${start_sector},," | sfdisk --append --no-reread "$boot_disk" >/dev/null 2>"$create_err_file"; then
         mkpart_ok=1
         if command -v sgdisk >/dev/null 2>&1; then
            sgdisk -c "${target_part_no}:${PERSIST_PARTLABEL}" "$boot_disk" >/dev/null 2>&1 || true
         elif command -v parted >/dev/null 2>&1; then
            parted -s "$boot_disk" name "$target_part_no" "$PERSIST_PARTLABEL" >/dev/null 2>&1 || true
         fi
      else
         boot_log "warning: sfdisk append failed on $boot_disk"
         if [ -s "$create_err_file" ]; then
            boot_log "sfdisk error: $(head -n1 "$create_err_file")"
         fi
      fi
 fi

 if [ "$mkpart_ok" -ne 1 ]; then
      boot_log "persistence create failed: parted, sgdisk, and sfdisk all failed"
      return 1
 fi

 if [ "$mbr_saved" -eq 1 ] && [ -f "$mbr_prefix_backup" ]; then
      if dd if="$mbr_prefix_backup" of="$boot_disk" bs=1 count=446 conv=notrunc status=none 2>/dev/null; then
         boot_log "restored MBR bootstrap bytes on $boot_disk"
      else
         boot_log "warning: failed to restore MBR bootstrap bytes on $boot_disk"
      fi
 fi

 if command -v partprobe >/dev/null 2>&1; then
    partprobe "$boot_disk" >/dev/null 2>&1 || true
 fi
 if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=8 >/dev/null 2>&1 || true
 fi

 persist_part="$(partition_path "$boot_disk" "$target_part_no" 2>/dev/null || true)"
 if [ -z "$persist_part" ]; then
    boot_log "persistence create failed: partition device for part ${target_part_no} not found"
    return 1
 fi

 case "$PERSIST_FS" in
   ext4)
      if ! mkfs.ext4 -F -L "$PERSIST_LABEL" "$persist_part" >/dev/null 2>&1; then
         boot_log "persistence create failed: mkfs.ext4 failed on $persist_part"
         return 1
      fi
      ;;
   fat32|vfat)
      if ! mkfs.vfat -F 32 -n "$PERSIST_LABEL_VFAT" "$persist_part" >/dev/null 2>&1; then
         boot_log "persistence create failed: mkfs.vfat failed on $persist_part"
         return 1
      fi
      ;;
 esac
 status_msg "persistent storage created: $persist_part"
 return 0
}

expand_persistence_partition_if_possible() {
 local boot_disk=""
 local persist_part=""
 local part_no=""
 local part_start=""
 local part_end=""
 local disk_last_sector=""
 local persist_fstype=""
 local before_size_bytes=""
 local after_size_bytes=""
 local target_mib=""
 local expand_err_file=""
 local -a parted_fix_args=()

 expand_err_file="/tmp/persist-expand.err.$$"
 rm -f "$expand_err_file" 2>/dev/null || true

 boot_disk="$(boot_disk_from_onboarding_label)"
 [ -n "$boot_disk" ] || return 1

 if command -v sgdisk >/dev/null 2>&1; then
      if sgdisk -e -g "$boot_disk" >/dev/null 2>"$expand_err_file"; then
         boot_log "repaired GPT metadata on $boot_disk before persistence expansion"
         if command -v partprobe >/dev/null 2>&1; then
            partprobe "$boot_disk" >/dev/null 2>&1 || true
         fi
         if command -v udevadm >/dev/null 2>&1; then
            udevadm settle --timeout=5 >/dev/null 2>&1 || true
         fi
      elif [ -s "$expand_err_file" ]; then
         boot_log "warning: GPT repair skipped on $boot_disk: $(head -n1 "$expand_err_file")"
      fi
 fi

 if parted --help 2>/dev/null | grep -q -- ' --fix'; then
      parted_fix_args=(-f)
 fi

 if [ -e "/dev/disk/by-partlabel/$PERSIST_PARTLABEL" ]; then
    persist_part="$(readlink -f "/dev/disk/by-partlabel/$PERSIST_PARTLABEL" 2>/dev/null || true)"
 fi
 if [ -z "$persist_part" ] && command -v blkid >/dev/null 2>&1; then
    persist_part="$(blkid -t PARTLABEL="$PERSIST_PARTLABEL" -o device 2>/dev/null | head -n1 || true)"
 fi
 if [ -z "$persist_part" ] && command -v blkid >/dev/null 2>&1; then
    persist_part="$(blkid -L "$PERSIST_LABEL" 2>/dev/null || true)"
 fi
 if [ -z "$persist_part" ] && command -v blkid >/dev/null 2>&1; then
    persist_part="$(blkid -L "$PERSIST_LABEL_VFAT" 2>/dev/null || true)"
 fi

 [ -n "$persist_part" ] || return 1
 [ -b "$persist_part" ] || return 1

 before_size_bytes="$(blockdev --getsize64 "$persist_part" 2>/dev/null || true)"
 if [ -n "$before_size_bytes" ]; then
    boot_log "persistence size before expansion: ${before_size_bytes} bytes ($persist_part)"
 fi

 part_no="$(lsblk -nrdo PARTN "$persist_part" 2>/dev/null | head -n1 || true)"
 if [ -z "$part_no" ]; then
    case "$persist_part" in
      *p[0-9]*) part_no="${persist_part##*p}" ;;
      *[0-9]) part_no="${persist_part##*[!0-9]}" ;;
    esac
 fi
 [ -n "$part_no" ] || return 1

 part_start="$(parted -ms "$boot_disk" unit s print 2>/dev/null | awk -F: -v pn="$part_no" '$1==pn {gsub("s","",$2); print $2}')"
 part_end="$(parted -ms "$boot_disk" unit s print 2>/dev/null | awk -F: -v pn="$part_no" '$1==pn {gsub("s","",$3); print $3}')"
 disk_last_sector="$(blockdev --getsz "$boot_disk" 2>/dev/null || true)"
 [ -n "$part_start" ] || { rm -f "$expand_err_file" 2>/dev/null || true; return 1; }
 [ -n "$part_end" ] || return 1
 [ -n "$disk_last_sector" ] || { rm -f "$expand_err_file" 2>/dev/null || true; return 1; }

 boot_log "persistence geometry: disk=$boot_disk part=$persist_part part_no=$part_no start=${part_start}s end=${part_end}s disk_end=${disk_last_sector}s"

 if [ $((part_end + 2048)) -ge "$disk_last_sector" ]; then
    if [ -n "$before_size_bytes" ]; then
      boot_log "persistence partition already occupies full disk: ${before_size_bytes} bytes"
    fi
    rm -f "$expand_err_file" 2>/dev/null || true
    return 1
 fi

 boot_log "expanding persistence partition $persist_part on $boot_disk"
 if ! parted -s "${parted_fix_args[@]}" "$boot_disk" unit s resizepart "$part_no" 100% >/dev/null 2>"$expand_err_file"; then
    boot_log "warning: failed to resize persistence partition"
    if [ -s "$expand_err_file" ]; then
      boot_log "parted resize error: $(head -n1 "$expand_err_file")"
    fi
    rm -f "$expand_err_file" 2>/dev/null || true
    return 1
 fi

 if command -v partprobe >/dev/null 2>&1; then
    partprobe "$boot_disk" >/dev/null 2>&1 || true
 fi
 if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=8 >/dev/null 2>&1 || true
 fi

 if [ -b "${boot_disk}p${part_no}" ]; then
    persist_part="${boot_disk}p${part_no}"
 elif [ -b "${boot_disk}${part_no}" ]; then
    persist_part="${boot_disk}${part_no}"
 fi

 persist_fstype="$(blkid -o value -s TYPE "$persist_part" 2>/dev/null || true)"
 if [ -z "$persist_fstype" ]; then
      boot_log "warning: persistence filesystem type unknown on $persist_part; skipping fs resize"
      rm -f "$expand_err_file" 2>/dev/null || true
      return 1
 fi

 boot_log "persistence filesystem detected: $persist_fstype"
 case "$persist_fstype" in
   ext4)
      if command -v resize2fs >/dev/null 2>&1; then
            if ! resize2fs "$persist_part" >/dev/null 2>"$expand_err_file"; then
               boot_log "warning: resize2fs failed on $persist_part"
               if [ -s "$expand_err_file" ]; then
                  boot_log "resize2fs error: $(head -n1 "$expand_err_file")"
               fi
            fi
      else
        boot_log "warning: resize2fs unavailable; ext4 expansion skipped"
      fi
      ;;
   vfat)
      boot_log "vfat persistence auto-resize disabled; run /usr/local/sbin/resize_persistence.sh from the menu when needed"
      ;;
   exfat|xfs|ntfs|ntfs3)
      boot_log "warning: filesystem $persist_fstype does not support automatic offline expansion here"
      ;;
 esac

 after_size_bytes="$(blockdev --getsize64 "$persist_part" 2>/dev/null || true)"
 if [ -n "$after_size_bytes" ]; then
    boot_log "persistence size after expansion: ${after_size_bytes} bytes ($persist_part)"
 fi

 rm -f "$expand_err_file" 2>/dev/null || true

 return 0
}

if [ "$PERSIST_DISABLED" = "1" ]; then
 boot_log "persistent storage disabled by kernel arg"
 boot_log "persistence scan/mount disabled by persist_disable=1"
else
 if [ "$PERSIST_AUTOEXPAND" = "1" ]; then
  expand_persistence_partition_if_possible || true
 else
  boot_log "persistence auto-expand disabled"
 fi

 for _persist_try in 1 2 3 4 5; do
  for PERSIST_DEV in $(find_persist_devices | awk 'NF && !seen[$0]++'); do
     [ -n "$PERSIST_DEV" ] || continue
     if mount_persist_volume "$PERSIST_DEV"; then
         if mountpoint -q /mnt/persist; then
             PERSISTENT_ROOT="/mnt/persist"
             break 2
         fi
     fi
  done

  if command -v udevadm >/dev/null 2>&1; then
     udevadm trigger --type=devices --action=add >/dev/null 2>&1 || true
    boot_log "waiting for udev settle (persistence scan)"
    if ! udevadm settle --timeout=5 >/dev/null 2>&1; then
       boot_log "warning: udev settle timed out during persistence scan"
    else
       boot_log "udev settle complete (persistence scan)"
    fi
  fi
  sleep 1
 done

 if [ -z "$PERSISTENT_ROOT" ]; then
  if [ "$PERSIST_AUTOCREATE" = "1" ]; then
      boot_log "persistent storage not found; attempting to create it"
    if create_persistence_partition_if_missing; then
     if command -v udevadm >/dev/null 2>&1; then
          udevadm trigger --type=devices --action=add >/dev/null 2>&1 || true
          udevadm settle --timeout=10 >/dev/null 2>&1 || true
     fi

     for PERSIST_DEV in $(find_persist_devices | awk 'NF && !seen[$0]++'); do
       [ -n "$PERSIST_DEV" ] || continue
       if mount_persist_volume "$PERSIST_DEV"; then
          if mountpoint -q /mnt/persist; then
             PERSISTENT_ROOT="/mnt/persist"
             break
          fi
       fi
     done
     fi
  else
     boot_log "persistent storage not found; auto-create disabled for boot safety"
  fi
 fi
fi

if [ -n "$PERSISTENT_ROOT" ]; then
 PERSISTENT_ZIP_DIR="$PERSISTENT_ROOT/zips"
 mkdir -p "$PERSISTENT_ZIP_DIR"
 BOOT_LOG_PERSIST_DIR="$PERSISTENT_ROOT/logs"
 BOOT_LOG_PERSIST_FILE="${BOOT_LOG_PERSIST_DIR}/boot.log"
 mkdir -p "$BOOT_LOG_PERSIST_DIR" 2>/dev/null || true
 if [ -f "$BOOT_LOG_FILE" ] && [ ! -f "$BOOT_LOG_PERSIST_FILE" ]; then
    cp "$BOOT_LOG_FILE" "$BOOT_LOG_PERSIST_FILE" 2>/dev/null || true
 fi
 PERSIST_READY=1
 boot_log "persistent storage ready: $PERSISTENT_ROOT"
 boot_log "zip path: $PERSISTENT_ZIP_DIR"
 boot_log "boot log mirror path: $BOOT_LOG_PERSIST_FILE"
else
 boot_log "warning: persistent storage unavailable for label=$PERSIST_LABEL partlabel=$PERSIST_PARTLABEL${PERSIST_DEV:+ dev=$PERSIST_DEV}"
fi

export PERSIST_READY PERSISTENT_ROOT PERSISTENT_ZIP_DIR

ONBOARDING_DIR="/boot/install"

persistent_override_sha256() {
 local path="$1"
 local digest=""

 if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$path" 2>/dev/null | awk '{print $1}' || true)"
 elif command -v busybox >/dev/null 2>&1; then
    digest="$(busybox sha256sum "$path" 2>/dev/null | awk '{print $1}' || true)"
 fi

 if [ -n "$digest" ]; then
    printf '%s\n' "$digest"
 else
    printf '%s\n' "unavailable"
 fi
}

apply_persistent_install_overrides() {
 local override_root=""
 local file_name=""
 local override_found=0
 local override_sha256=""

 if [ "$PERSIST_READY" != "1" ] || [ -z "$PERSISTENT_ROOT" ]; then
    return 0
 fi

 override_root="$PERSISTENT_ROOT/runtime"
 if [ ! -d "$override_root" ]; then
    return 0
 fi

 for file_name in \
    build_activation_json.sh \
    install-profile \
    menu-backend \
    menu.sh \
    menu_gui_common.sh \
    menu_gui_user.sh \
    menu_gui.sh \
    create_internal_boot.sh \
    create_flash_boot.sh \
    release_pending_provision.sh \
    update_partner_runtime.sh \
    zip.sh; do
    if [ -f "$override_root/$file_name" ]; then
      override_found=1
      break
    fi
 done

 if [ "$override_found" = "1" ]; then
    status_msg "warning: trusted persistence runtime overrides found in $override_root"
    status_msg "warning: runtime overrides can replace installer scripts and run as root"
 fi

 for file_name in \
    build_activation_json.sh \
    install-profile \
    menu-backend \
    menu.sh \
    menu_gui_common.sh \
    menu_gui_user.sh \
    menu_gui.sh \
    create_internal_boot.sh \
    create_flash_boot.sh \
    release_pending_provision.sh \
    update_partner_runtime.sh \
    zip.sh; do
    if [ -f "$override_root/$file_name" ]; then
      override_sha256="$(persistent_override_sha256 "$override_root/$file_name")"
      cp -f "$override_root/$file_name" "$ONBOARDING_DIR/$file_name"
      case "$file_name" in
            install-profile)
          chmod 0644 "$ONBOARDING_DIR/$file_name" 2>/dev/null || true
          ;;
        *)
          chmod +x "$ONBOARDING_DIR/$file_name" 2>/dev/null || true
          ;;
      esac
         boot_log "applied persistent install override: $file_name sha256=$override_sha256"
    fi
 done

 # If runtime provides only menu_gui.sh, promote it to menu.sh so it wins launcher priority.
 if [ -f "$override_root/menu_gui.sh" ] && [ ! -f "$override_root/menu.sh" ]; then
    override_sha256="$(persistent_override_sha256 "$override_root/menu_gui.sh")"
    cp -f "$override_root/menu_gui.sh" "$ONBOARDING_DIR/menu.sh"
    chmod +x "$ONBOARDING_DIR/menu.sh" 2>/dev/null || true
    boot_log "applied persistent install override: menu_gui.sh -> menu.sh sha256=$override_sha256"
 fi
}

launch_onboarding_target() {
 local menu_script=""
 local menu_backend_default_file=""
 local menu_backend_default=""

 if grep -qw 'onboarding_mode=shell' /proc/cmdline 2>/dev/null; then
    boot_log "launching interactive shell"
    if command -v cttyhack >/dev/null 2>&1; then
        exec cttyhack /bin/bash -i
    elif [ -x /bin/busybox ]; then
        exec /bin/busybox cttyhack /bin/bash -i
    else
        exec /bin/bash -i </dev/tty0 >/dev/tty0 2>&1
    fi
 fi

 apply_persistent_install_overrides

 menu_backend_default_file="$ONBOARDING_DIR/menu-backend"
 if [ -z "${MENU_BACKEND:-}" ] && [ -f "$menu_backend_default_file" ]; then
    menu_backend_default="$(tr -d '[:space:]' < "$menu_backend_default_file" 2>/dev/null || true)"
    case "${menu_backend_default,,}" in
      whiptail|dialog|text)
        export MENU_BACKEND="${menu_backend_default,,}"
        boot_log "menu backend default applied: ${MENU_BACKEND}"
        ;;
    esac
 fi

 for menu_script in \
    "$ONBOARDING_DIR/menu.sh" \
    "$ONBOARDING_DIR/menu_gui_user.sh" \
    "$ONBOARDING_DIR/menu_gui.sh"; do
    [ -f "$menu_script" ] && break
 done

 if [ -z "$menu_script" ] || [ ! -f "$menu_script" ]; then
    boot_log "error: no menu script found under /boot/install"
    if [ -w /dev/console ]; then
       printf '[init] ERROR: no menu script found under /boot/install\n' > /dev/console 2>/dev/null || true
    fi
    sleep 2
    return
 fi

 boot_log "launching onboarding menu"
 if command -v cttyhack >/dev/null 2>&1; then
    cttyhack /bin/bash "$menu_script" || true
    return
 elif [ -x /bin/busybox ]; then
    /bin/busybox cttyhack /bin/bash "$menu_script" || true
    return
 fi

 /bin/bash "$menu_script" </dev/tty0 >/dev/tty0 2>&1 || \
    /bin/bash "$menu_script" </dev/console >/dev/console 2>&1 || true
}

while true; do
 launch_onboarding_target
 boot_log "menu.sh exited; restarting in 1 second"
 sleep 1
done
EOF
sudo chmod +x "$ROOTFS/init"

sudo touch "$ROOTFS/etc/machine-id"

echo "Packing initrd (this can take a while)..."
(
 cd "$ROOTFS"
 sudo find . -print0 | sudo cpio --quiet --null -o --format=newc 2>/dev/null | xz -T0 -9e --check=crc32 > "$ISO/boot/initrd"
)
echo "Initrd created: $(du -h "$ISO/boot/initrd" | awk '{print $1}')"

[ -f "$ISO/boot/vmlinuz" ] || { echo "Staged ISO kernel missing: $ISO/boot/vmlinuz" >&2; exit 1; }
[ -f "$ISO/boot/initrd" ] || { echo "Staged ISO initrd missing: $ISO/boot/initrd" >&2; exit 1; }

cat <<EOF > "$WORKDIR/embedded-grub-efi.cfg"
insmod efi_gop
insmod efi_uga
insmod all_video
insmod iso9660
insmod udf
insmod fat
insmod part_gpt
insmod part_msdos
insmod search
insmod search_fs_file
insmod search_label
insmod font
insmod png
insmod gfxterm
insmod linux
insmod gzio
set timeout_style=menu
set default=0
terminal_input console
echo "EFI GRUB loaded"

set timeout=5

# Prefer explicit CD partition nodes first; some BIOS paths expose ISO there.
if [ -e (cd0,gpt1)/boot/vmlinuz ]; then
 set root=(cd0,gpt1)
elif [ -e (cd0,msdos1)/boot/vmlinuz ]; then
 set root=(cd0,msdos1)
elif [ -e (cd0)/boot/vmlinuz ]; then
 set root=(cd0)
else
 search --no-floppy --label --set=root INSTALLER || search --no-floppy --label --set=root ONBOARDING || search --no-floppy --file --set=root /boot/vmlinuz || true
fi
if [ "\$root" = "memdisk" ] || [ "\$root" = "(memdisk)" ] || [ -z "\$root" ]; then
 if [ -e (cd0,gpt1)/boot/vmlinuz ]; then
  set root=(cd0,gpt1)
 elif [ -e (cd0,msdos1)/boot/vmlinuz ]; then
  set root=(cd0,msdos1)
 elif [ -e (cd0)/boot/vmlinuz ]; then
  set root=(cd0)
 else
  set root=(cd0)
 fi
fi
if loadfont /boot/grub/themes/unraid/terminus-14.pf2 ; then
 set gfxmode=auto
 terminal_output gfxterm
 set theme=/boot/grub/themes/unraid/theme.txt
 export theme
else
 terminal_output console
fi

menuentry "Internal Boot Setup" {
 echo "Loading......"
 sleep 1
 linux (\$root)/boot/vmlinuz root=/dev/ram0 rw rdinit=/init loglevel=3 console=tty0 consoleblank=0${BOOT_PERSIST_KERNEL_ARGS}
 initrd (\$root)/boot/initrd
}

menuentry "Memtest86+" {
 if search --no-floppy --file --set=memtest_root /EFI/BOOT/MEMTESTX64.EFI ; then
  chainloader (\$memtest_root)/EFI/BOOT/MEMTESTX64.EFI
  boot
 elif search --no-floppy --file --set=memtest_root /boot/memtest86+x64.efi ; then
  chainloader (\$memtest_root)/boot/memtest86+x64.efi
  boot
 else
  echo "Memtest payload not found on boot media."
  echo "Expected /EFI/BOOT/MEMTESTX64.EFI or /boot/memtest86+x64.efi"
 fi
}
EOF

cat <<EOF > "$WORKDIR/embedded-grub-bios.cfg"
insmod biosdisk
insmod iso9660
insmod all_video
insmod gfxterm
insmod font
insmod png
insmod search
insmod search_fs_file
insmod search_label
insmod part_gpt
insmod part_msdos
insmod linux
insmod gzio
set timeout=5
set timeout_style=menu
set default=0

if [ -e (cd0,gpt1)/boot/vmlinuz ]; then
 set root=(cd0,gpt1)
elif [ -e (cd0,msdos1)/boot/vmlinuz ]; then
 set root=(cd0,msdos1)
elif [ -e (cd0)/boot/vmlinuz ]; then
 set root=(cd0)
else
 search --no-floppy --label --set=root INSTALLER || search --no-floppy --label --set=root ONBOARDING || search --no-floppy --file --set=root /boot/vmlinuz || true
fi
if [ "\$root" = "memdisk" ] || [ "\$root" = "(memdisk)" ] || [ -z "\$root" ]; then
 if [ -e (cd0,gpt1)/boot/vmlinuz ]; then
  set root=(cd0,gpt1)
 elif [ -e (cd0,msdos1)/boot/vmlinuz ]; then
  set root=(cd0,msdos1)
 elif [ -e (cd0)/boot/vmlinuz ]; then
  set root=(cd0)
 else
  set root=(cd0)
 fi
fi
if loadfont /boot/grub/themes/unraid/terminus-14.pf2 ; then
 set gfxmode=auto
 terminal_output gfxterm
 set theme=/boot/grub/themes/unraid/theme.txt
 export theme
else
 terminal_output console
fi

menuentry "Internal Boot Setup" {
 echo "Loading....."
 sleep 1
 linux (\$root)/boot/vmlinuz root=/dev/ram0 rw rdinit=/init loglevel=3 console=tty0 consoleblank=0
 initrd (\$root)/boot/initrd
}

menuentry "Memtest86+" {
 if search --no-floppy --file --set=memtest_root /boot/memtest86+x64.efi ; then
  chainloader (\$memtest_root)/boot/memtest86+x64.efi
  boot
 elif search --no-floppy --file --set=memtest_root /EFI/BOOT/MEMTESTX64.EFI ; then
  chainloader (\$memtest_root)/EFI/BOOT/MEMTESTX64.EFI
  boot
 else
  echo "Memtest payload not found on boot media."
  echo "Expected /boot/memtest86+x64.efi or /EFI/BOOT/MEMTESTX64.EFI"
 fi
}
EOF

cat <<EOF > "$ISO_THEME_DIR/theme.txt"
# Generated for build-iso.sh
title-text: ""
desktop-image: "background.png"
desktop-color: "#000000"
terminal-font: "Terminus Regular 14"
terminal-box: "terminal_box_*.png"
terminal-left: "0"
terminal-top: "0"
terminal-width: "100%"
terminal-height: "100%"
terminal-border: "0"

+ label {
    top = 28%
    left = 15%
    align = "center"
    id = "header"
    text = "Machine Name:       $DISPLAY_NAME"
    color = "#cccccc"
    font = "Nudista SemiBold Regular 24"
}
+ label {
    top = 31%
    left = 15%
    align = "center"
    id = "header"
    text = "Kernel Release:     $KERNEL_RELEASE"
    color = "#cccccc"
    font = "Nudista SemiBold Regular 24"
}
+ label {
    top = 35%
    left = 15%
    align = "center"
   id = "__timeout__"
   text = "Selected option will start in %d seconds"
    color = "#cccccc"
    font = "Nudista SemiBold Regular 24"
}
+ boot_menu {
    top = 40%
    left = 15%
    width = 55%
    height = 65%
    item_font = "Nudista SemiBold Regular 24"
    item_color = "#cccccc"
    selected_item_color = "#ffffff"
    icon_width = 36
    icon_height = 36
    item_icon_space = 20
    item_height = 40
    item_padding = 2
    item_spacing = 10
    selected_item_pixmap_style = "select_*.png"
}
EOF

cat <<EOF > "$ISO/boot/grub/grub.cfg"
set timeout=5
set timeout_style=menu
set default=0
insmod all_video
insmod gfxterm
insmod font
insmod search
insmod search_fs_file
insmod part_gpt
insmod part_msdos
insmod png

if loadfont /boot/grub/themes/unraid/terminus-14.pf2 ; then
 set gfxmode=auto
 terminal_output gfxterm
 set theme=/boot/grub/themes/unraid/theme.txt
 export theme
else
 terminal_output console
fi

menuentry "Internal Boot Setup" {
 echo "Loading....."
 sleep 1
 if [ -e (cd0,gpt1)/boot/vmlinuz ]; then
  set root=(cd0,gpt1)
 elif [ -e (cd0,msdos1)/boot/vmlinuz ]; then
  set root=(cd0,msdos1)
 elif [ -e (cd0)/boot/vmlinuz ]; then
  set root=(cd0)
 else
    search --no-floppy --label --set=root INSTALLER || search --no-floppy --label --set=root ONBOARDING || search --no-floppy --file --set=root /boot/vmlinuz || true
 fi
 if [ "\$root" = "memdisk" ] || [ "\$root" = "(memdisk)" ] || [ -z "\$root" ]; then
   if [ -e (cd0,gpt1)/boot/vmlinuz ]; then
    set root=(cd0,gpt1)
   elif [ -e (cd0,msdos1)/boot/vmlinuz ]; then
    set root=(cd0,msdos1)
   elif [ -e (cd0)/boot/vmlinuz ]; then
    set root=(cd0)
   else
    set root=(cd0)
   fi
 fi
 linux (\$root)/boot/vmlinuz root=/dev/ram0 rw rdinit=/init loglevel=3 console=tty0 consoleblank=0
 initrd (\$root)/boot/initrd
}

menuentry "Memtest86+" {
 if search --no-floppy --file --set=memtest_root /EFI/BOOT/MEMTESTX64.EFI ; then
  chainloader (\$memtest_root)/EFI/BOOT/MEMTESTX64.EFI
  boot
 elif search --no-floppy --file --set=memtest_root /boot/memtest86+x64.efi ; then
  chainloader (\$memtest_root)/boot/memtest86+x64.efi
  boot
 else
  echo "Memtest payload not found on boot media."
  echo "Expected /EFI/BOOT/MEMTESTX64.EFI or /boot/memtest86+x64.efi"
 fi
}
EOF

echo "Generating standalone GRUB EFI image..."
grub-mkstandalone -O x86_64-efi \
 -o "$WORKDIR/BOOTX64.EFI" \
 --modules="efi_gop efi_uga all_video gfxterm font png iso9660 udf fat part_gpt part_msdos search search_fs_file search_label linux gzio normal test echo chain" \
 "boot/grub/grub.cfg=$WORKDIR/embedded-grub-efi.cfg"

echo "Generating standalone GRUB BIOS image..."
GRUB_CDBOOT_IMG="$(resolve_grub_cdboot_path || true)"
[ -n "$GRUB_CDBOOT_IMG" ] || { echo "Missing GRUB BIOS cdboot image (cdboot.img)." >&2; exit 1; }

grub-mkimage -O i386-pc \
 -o "$WORKDIR/core.img" \
 -p /boot/grub \
 -c "$WORKDIR/embedded-grub-bios.cfg" \
 biosdisk all_video gfxterm font png iso9660 part_gpt part_msdos search search_fs_file search_label linux gzio normal test echo chain

cat "$GRUB_CDBOOT_IMG" "$WORKDIR/core.img" > "$ISO/boot/grub/eltorito.img"

dd if=/dev/zero of="$WORKDIR/efiboot.img" bs=1M count=20 status=none
mkfs.vfat "$WORKDIR/efiboot.img" >/dev/null
mmd -i "$WORKDIR/efiboot.img" ::/EFI ::/EFI/BOOT
mcopy -i "$WORKDIR/efiboot.img" "$WORKDIR/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
if [ -n "$MEMTEST_X64_SOURCE" ] && [ -f "$MEMTEST_X64_SOURCE" ]; then
 mcopy -i "$WORKDIR/efiboot.img" "$MEMTEST_X64_SOURCE" ::/EFI/BOOT/MEMTESTX64.EFI
fi
if [ -n "$MEMTEST_IA32_SOURCE" ] && [ -f "$MEMTEST_IA32_SOURCE" ]; then
 mcopy -i "$WORKDIR/efiboot.img" "$MEMTEST_IA32_SOURCE" ::/EFI/BOOT/MEMTESTIA32.EFI
fi
cp "$WORKDIR/efiboot.img" "$ISO/boot/efiboot.img"

ISOHYBRID_MBR="$(resolve_isohybrid_mbr_path || true)"
XORRISO_HYBRID_ARGS=(-isohybrid-gpt-basdat)
if [ -n "$ISOHYBRID_MBR" ]; then
 XORRISO_HYBRID_ARGS+=(-isohybrid-mbr "$ISOHYBRID_MBR")
 echo "Using isohybrid MBR stub: $ISOHYBRID_MBR"
else
 echo "Warning: isohybrid MBR stub not found; USB BIOS boot may fail on some firmware." >&2
fi

echo "Building ISO with xorriso..."
xorriso -as mkisofs -o "$WORKDIR/zfs-linux-$KERNEL_VERSION.iso" \
 -V "$MEDIA_LABEL" \
 "${XORRISO_HYBRID_ARGS[@]}" \
 -b boot/grub/eltorito.img -c boot.catalog \
 -no-emul-boot -boot-load-size -1 -boot-info-table \
 -eltorito-alt-boot -e boot/efiboot.img -no-emul-boot \
 "$ISO"

mkdir -p "$(dirname "$PUBLISH_ISO")"
cp "$WORKDIR/zfs-linux-$KERNEL_VERSION.iso" "$PUBLISH_ISO"

echo
echo "ISO built:"
echo "$WORKDIR/zfs-linux-$KERNEL_VERSION.iso"
echo "Published ISO: $PUBLISH_ISO"
