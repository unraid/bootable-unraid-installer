#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build/refresh kernel and OpenZFS cache artifacts only.

Usage:
  ./build-kernel-zfs-cache.sh [--clean]

Options:
  --clean    Force clean rebuild of kernel and OpenZFS cache artifacts.
  -h, --help Show this help.

Outputs in WORKDIR (default: ./zfs-live-build):
  .kernel-version-current
  .kernel-release-current
  .kernel-src-dir-current
  .kernel-staging-dir-current
  .zfs-tag-current
EOF
}

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
CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y
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
    zfs-[0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$tag" ;;
    *) fatal "Unable to resolve latest OpenZFS release tag" ;;
  esac
}

normalize_zfs_tag() {
  local raw_tag="$1"
  case "$raw_tag" in
    zfs-[0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$raw_tag"; return 0 ;;
    [0-9]*.[0-9]*.[0-9]*) printf 'zfs-%s\n' "$raw_tag"; return 0 ;;
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

download_kernel_tarball() {
  download_to_file "https://cdn.kernel.org/pub/linux/kernel/v6.x/$KERNEL_TARBALL" "$KERNEL_TARBALL"
}

ensure_kernel_source_tree() {
  if [ ! -f "$KERNEL_TARBALL" ]; then
    echo "Kernel source tarball not found; downloading..."
    download_kernel_tarball
  fi

  if ! xz -t "$KERNEL_TARBALL" >/dev/null 2>&1; then
    echo "Kernel tarball is invalid or incomplete; re-downloading..."
    rm -f "$KERNEL_TARBALL"
    download_kernel_tarball
  fi

  if ! xz -t "$KERNEL_TARBALL" >/dev/null 2>&1; then
    echo "Kernel tarball xz validation failed after re-download: $KERNEL_TARBALL" >&2
    exit 1
  fi

  if [ ! -d "$KERNEL_SRC_DIR" ]; then
    echo "Kernel source tree not found; extracting..."
    if ! tar -xJf "$KERNEL_TARBALL"; then
      echo "Kernel extraction failed for $KERNEL_TARBALL. Check free space and xz/tar support." >&2
      exit 1
    fi
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKDIR="${WORKDIR:-$REPO_ROOT/zfs-live-build}"
KERNEL_STAGING_DIR="$WORKDIR/kernel-staging"
ZFS_USERSPACE_STAGING_DIR="$WORKDIR/zfs-userspace-staging"
KERNEL_SERIES="${KERNEL_SERIES:-6.18}"
KERNEL_VERSION="${KERNEL_VERSION:-}"
ZFS_TAG="${ZFS_TAG:-}"
VERSION_LOCK_HASH=""
KERNEL_CONFIG_TARGET="defconfig"
KERNEL_CONFIG_FILE="${KERNEL_CONFIG_FILE:-}"
DEFAULT_KERNEL_CONFIG_FILE="$SCRIPT_DIR/config"
ZFS_SRC_DIR="$WORKDIR/zfs"
JOBS="${JOBS:-$(nproc)}"
CLEAN_BUILD=0

while (($#)); do
  case "$1" in
    --clean)
      CLEAN_BUILD=1
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

require_cmd tar
require_cmd xz
require_cmd git
require_cmd make

KERNEL_VERSION="$(resolve_kernel_version)"
KERNEL_TARBALL="linux-$KERNEL_VERSION.tar.xz"
KERNEL_SRC_DIR="$WORKDIR/linux-$KERNEL_VERSION"
KERNEL_BUILD_STAMP="$WORKDIR/.kernel-build-$KERNEL_VERSION.stamp"
ZFS_BUILD_STAMP="$WORKDIR/.zfs-build-$KERNEL_VERSION.stamp"
ZFS_USERSPACE_STAMP="$WORKDIR/.zfs-userspace-install-$KERNEL_VERSION.stamp"
KERNEL_RELEASE_FILE="$WORKDIR/.kernel-release-$KERNEL_VERSION"

if [ "$CLEAN_BUILD" = "1" ]; then
  echo "Clean build requested: removing kernel/ZFS build artifacts..."
  rm -f "$KERNEL_BUILD_STAMP" "$ZFS_BUILD_STAMP" "$ZFS_USERSPACE_STAMP" "$KERNEL_RELEASE_FILE" "$ZFS_TAG_FILE"
  rm -rf "$KERNEL_SRC_DIR" "$KERNEL_STAGING_DIR" "$ZFS_SRC_DIR" "$ZFS_USERSPACE_STAGING_DIR"
fi

echo "Using kernel version: $KERNEL_VERSION"
echo "Clean build: $CLEAN_BUILD"

if [ -n "$VERSION_LOCK_HASH" ]; then
  KERNEL_INPUT_FINGERPRINT="$VERSION_LOCK_HASH"
else
  echo "Preparing kernel source fingerprint input..."
  ensure_kernel_source_tree
  KERNEL_CONFIG_FINGERPRINT="$(kernel_config_overrides | sha256sum | awk '{print $1}')"
  if [ -n "$KERNEL_CONFIG_FILE" ] && [ -f "$KERNEL_CONFIG_FILE" ]; then
    KERNEL_CONFIG_FILE_FINGERPRINT="$(sha256sum "$KERNEL_CONFIG_FILE" | awk '{print $1}')"
  else
    KERNEL_CONFIG_FILE_FINGERPRINT="none"
  fi
  KERNEL_INPUT_FINGERPRINT="$(sha256sum "$WORKDIR/$KERNEL_TARBALL" | awk '{print $1}'):${KERNEL_CONFIG_TARGET}:${KERNEL_CONFIG_FILE_FINGERPRINT}:${KERNEL_CONFIG_FINGERPRINT}"
fi

if [ -f "$KERNEL_BUILD_STAMP" ] && [ "$(cat "$KERNEL_BUILD_STAMP")" = "$KERNEL_INPUT_FINGERPRINT" ]; then
  echo "Kernel inputs unchanged; skipping kernel compile/install."
else
  kernel_rebuild_reason="changed"
  if [ -f "$KERNEL_BUILD_STAMP" ]; then
    echo "Kernel cache miss: input fingerprint changed."
    echo "Previous kernel fingerprint: $(cat "$KERNEL_BUILD_STAMP")"
    echo "Current kernel fingerprint:  $KERNEL_INPUT_FINGERPRINT"
  else
    kernel_rebuild_reason="missing"
    echo "Kernel cache miss: build stamp not found at $KERNEL_BUILD_STAMP"
  fi

  if [ "$kernel_rebuild_reason" = "changed" ] && [ "$CLEAN_BUILD" != "1" ]; then
    echo "Kernel rebuild is disabled unless --clean is specified." >&2
    echo "Run with --clean to rebuild changed kernel artifacts, or restore a matching cache." >&2
    exit 1
  fi
  if [ "$kernel_rebuild_reason" = "missing" ] && [ "$CLEAN_BUILD" != "1" ]; then
    echo "Kernel cache section missing; rebuilding kernel artifacts without --clean."
  fi

  echo "Building kernel..."
  ensure_kernel_source_tree
  cd "$KERNEL_SRC_DIR"
  apply_kernel_config_overrides
  make -j"$JOBS"
  rm -rf "$KERNEL_STAGING_DIR"
  make modules_install INSTALL_MOD_PATH="$KERNEL_STAGING_DIR"
  printf '%s\n' "$KERNEL_INPUT_FINGERPRINT" > "$KERNEL_BUILD_STAMP"
fi

if [ ! -d "$KERNEL_SRC_DIR" ]; then
  echo "Missing kernel source tree: $KERNEL_SRC_DIR" >&2
  echo "Restore cache or run with --clean to prepare kernel sources." >&2
  exit 1
fi

cd "$KERNEL_SRC_DIR"
KERNEL_RELEASE="$(make -s kernelrelease)"
printf '%s\n' "$KERNEL_RELEASE" > "$KERNEL_RELEASE_FILE"

if [ ! -f "$KERNEL_SRC_DIR/arch/x86/boot/bzImage" ]; then
  echo "Missing staged kernel image: $KERNEL_SRC_DIR/arch/x86/boot/bzImage" >&2
  echo "Kernel rebuild is disabled unless --clean is specified." >&2
  exit 1
fi

if [ ! -d "$KERNEL_STAGING_DIR/lib/modules/$KERNEL_RELEASE" ]; then
  echo "Missing staged kernel modules: $KERNEL_STAGING_DIR/lib/modules/$KERNEL_RELEASE" >&2
  echo "Kernel rebuild is disabled unless --clean is specified." >&2
  exit 1
fi

cd "$WORKDIR"

ZFS_TAG="$(resolve_zfs_tag)"
printf '%s\n' "$ZFS_TAG" > "$ZFS_TAG_FILE"
echo "Using OpenZFS release tag: $ZFS_TAG"

if [ ! -d "$ZFS_SRC_DIR" ]; then
  git clone https://github.com/openzfs/zfs "$ZFS_SRC_DIR"
fi

cd "$ZFS_SRC_DIR"
git fetch --tags --force >/dev/null 2>&1 || true
git checkout --force "$ZFS_TAG"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ZFS_TREE_STATE="$ZFS_TAG:$(git rev-parse HEAD)"
else
  ZFS_TREE_STATE="non-git:$(find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
fi

ZFS_BUILD_FINGERPRINT="${ZFS_TREE_STATE}:$(readlink -f "$KERNEL_SRC_DIR")"
if [ -n "$VERSION_LOCK_HASH" ]; then
  ZFS_BUILD_FINGERPRINT="$VERSION_LOCK_HASH"
fi

if [ -f "$ZFS_BUILD_STAMP" ] && [ "$(cat "$ZFS_BUILD_STAMP")" = "$ZFS_BUILD_FINGERPRINT" ]; then
  echo "OpenZFS inputs unchanged; skipping OpenZFS build/install."
else
  zfs_rebuild_reason="changed"
  if [ -f "$ZFS_BUILD_STAMP" ]; then
    echo "OpenZFS cache miss: input fingerprint changed."
    echo "Previous OpenZFS fingerprint: $(cat "$ZFS_BUILD_STAMP")"
    echo "Current OpenZFS fingerprint:  $ZFS_BUILD_FINGERPRINT"
  else
    zfs_rebuild_reason="missing"
    echo "OpenZFS cache miss: build stamp not found at $ZFS_BUILD_STAMP"
  fi

  if [ "$zfs_rebuild_reason" = "changed" ] && [ "$CLEAN_BUILD" != "1" ]; then
    echo "OpenZFS rebuild is disabled unless --clean is specified." >&2
    echo "Run with --clean to rebuild changed OpenZFS artifacts, or restore a matching cache." >&2
    exit 1
  fi
  if [ "$zfs_rebuild_reason" = "missing" ] && [ "$CLEAN_BUILD" != "1" ]; then
    echo "OpenZFS cache section missing; rebuilding OpenZFS artifacts without --clean."
  fi

  echo "Building OpenZFS..."
  ./autogen.sh
  ./configure --with-linux="$KERNEL_SRC_DIR"
  make -j"$JOBS"
  printf '%s\n' "$ZFS_BUILD_FINGERPRINT" > "$ZFS_BUILD_STAMP"
fi

echo "Installing OpenZFS kernel modules into staged module tree..."
if make -C module -n install >/dev/null 2>&1; then
  if ! make -C module install DESTDIR="$KERNEL_STAGING_DIR" INSTALL_MOD_PATH="$KERNEL_STAGING_DIR" KERNELRELEASE="$KERNEL_RELEASE"; then
    echo "OpenZFS module install target failed; falling back to direct module staging..."
    module_dest_dir="$KERNEL_STAGING_DIR/lib/modules/$KERNEL_RELEASE/extra/zfs"
    mkdir -p "$module_dest_dir"
    while IFS= read -r -d '' ko_file; do
      cp "$ko_file" "$module_dest_dir/"
    done < <(find module -type f -name '*.ko' -print0)
  fi
else
  if ! make install DESTDIR="$KERNEL_STAGING_DIR" INSTALL_MOD_PATH="$KERNEL_STAGING_DIR" KERNELRELEASE="$KERNEL_RELEASE"; then
    echo "OpenZFS install target failed; falling back to direct module staging..."
    module_dest_dir="$KERNEL_STAGING_DIR/lib/modules/$KERNEL_RELEASE/extra/zfs"
    mkdir -p "$module_dest_dir"
    while IFS= read -r -d '' ko_file; do
      cp "$ko_file" "$module_dest_dir/"
    done < <(find module -type f -name '*.ko' -print0)
  fi
fi

if ! find "$KERNEL_STAGING_DIR/lib/modules/$KERNEL_RELEASE" -type f \( -name 'zfs.ko' -o -name 'zfs.ko.xz' -o -name 'zfs.ko.zst' \) -print -quit | grep -q .; then
  echo "Missing staged ZFS module under $KERNEL_STAGING_DIR/lib/modules/$KERNEL_RELEASE" >&2
  exit 1
fi

ZFS_USERSPACE_FINGERPRINT="${ZFS_BUILD_FINGERPRINT}:${KERNEL_RELEASE}"
if [ -f "$ZFS_USERSPACE_STAMP" ] && [ "$(cat "$ZFS_USERSPACE_STAMP")" = "$ZFS_USERSPACE_FINGERPRINT" ] && [ -d "$ZFS_USERSPACE_STAGING_DIR/usr/local" ]; then
  echo "OpenZFS userspace staging unchanged; skipping userspace install staging."
else
  echo "Staging OpenZFS userspace install tree..."
  rm -rf "$ZFS_USERSPACE_STAGING_DIR"
  mkdir -p "$ZFS_USERSPACE_STAGING_DIR"
  make install DESTDIR="$ZFS_USERSPACE_STAGING_DIR"
  printf '%s\n' "$ZFS_USERSPACE_FINGERPRINT" > "$ZFS_USERSPACE_STAMP"
fi

cd "$WORKDIR"
printf '%s\n' "$KERNEL_VERSION" > "$WORKDIR/.kernel-version-current"
printf '%s\n' "$KERNEL_RELEASE" > "$WORKDIR/.kernel-release-current"
printf '%s\n' "$KERNEL_SRC_DIR" > "$WORKDIR/.kernel-src-dir-current"
printf '%s\n' "$KERNEL_STAGING_DIR" > "$WORKDIR/.kernel-staging-dir-current"
printf '%s\n' "$ZFS_TAG" > "$WORKDIR/.zfs-tag-current"

echo "kernel/OpenZFS cache build complete."
echo "Kernel version: $KERNEL_VERSION"
echo "Kernel release: $KERNEL_RELEASE"
echo "Kernel source:  $KERNEL_SRC_DIR"
echo "Module staging: $KERNEL_STAGING_DIR"
echo "OpenZFS tag:    $ZFS_TAG"
