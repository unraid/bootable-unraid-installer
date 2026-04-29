#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build user install images.

Usage:
  ./build-install-images.sh [--user] [--mode full|grub-iso] [--menu-ui gui] [--menu-backend auto|whiptail|dialog|text] [--persist-fs ext4|fat32|vfat] [--size SIZE] [--clean-build] [--force]

Options:
  --user              Build install-user images (default behavior)
  --mode MODE         Mode for first ISO build: full or grub-iso (default: full)
  --menu-ui UI        Default menu implementation in built image: gui only
  --menu-backend BK   Default menu backend in built image: auto|whiptail|dialog|text
  --persist-fs FS     Default persistence filesystem for boot auto-create: ext4|fat32|vfat
  --size SIZE         Image size passed to build-usb-native.sh (default: auto)
  --clean-build       Force clean kernel/ZFS rebuild (applies to full-mode ISO build)
  --force             Overwrite existing output files
  -h, --help          Show this help

Outputs (in ./zfs-live-build):
  install-user.iso
  install-user.img
  install-user-minimal.img

Published copies:
  $PUBLISH_DIR/install-user.iso
  $PUBLISH_DIR/install-user.img
  $PUBLISH_DIR/install-user-minimal.img
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKDIR="${WORKDIR:-$REPO_ROOT/zfs-live-build}"
DEFAULT_SEED_DIR=""
FIRST_MODE="full"
MENU_UI="gui"
MENU_BACKEND="auto"
PERSIST_FS=""
IMAGE_SIZE="auto"
FORCE=0
CLEAN_BUILD=0
PUBLISH_DIR="${PUBLISH_DIR:-$REPO_ROOT/artifacts/published}"
PUBLISH_ENABLED="${PUBLISH_ENABLED:-1}"

while (($#)); do
  case "$1" in
    --user)
      shift
      ;;
    --mode)
      [[ $# -ge 2 ]] || { echo "Missing value for --mode" >&2; exit 1; }
      FIRST_MODE="$2"
      shift 2
      ;;
    --size)
      [[ $# -ge 2 ]] || { echo "Missing value for --size" >&2; exit 1; }
      IMAGE_SIZE="$2"
      shift 2
      ;;
    --menu-ui)
      [[ $# -ge 2 ]] || { echo "Missing value for --menu-ui" >&2; exit 1; }
      MENU_UI="$2"
      shift 2
      ;;
    --menu-backend)
      [[ $# -ge 2 ]] || { echo "Missing value for --menu-backend" >&2; exit 1; }
      MENU_BACKEND="$2"
      shift 2
      ;;
    --persist-fs)
      [[ $# -ge 2 ]] || { echo "Missing value for --persist-fs" >&2; exit 1; }
      PERSIST_FS="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --clean-build)
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

case "$FIRST_MODE" in
  full|grub-iso) ;;
  *)
    echo "--mode must be 'full' or 'grub-iso'" >&2
    exit 1
    ;;
esac

case "$MENU_UI" in
  gui) ;;
  *)
    echo "--menu-ui must be 'gui'" >&2
    exit 1
    ;;
esac

case "${MENU_BACKEND,,}" in
  auto|whiptail|dialog|text)
    MENU_BACKEND="${MENU_BACKEND,,}"
    ;;
  *)
    echo "--menu-backend must be auto, whiptail, dialog, or text" >&2
    exit 1
    ;;
esac

if [[ -n "$PERSIST_FS" ]]; then
  case "${PERSIST_FS,,}" in
    ext4|fat32|vfat)
      PERSIST_FS="${PERSIST_FS,,}"
      ;;
    *)
      echo "--persist-fs must be ext4, fat32, or vfat" >&2
      exit 1
      ;;
  esac
fi

if [[ "$CLEAN_BUILD" -eq 1 && "$FIRST_MODE" != "full" ]]; then
  echo "--clean-build requires --mode full" >&2
  exit 1
fi

mkdir -p "$WORKDIR"

if [[ -n "${SEED_DIR:-}" ]]; then
  DEFAULT_SEED_DIR="$SEED_DIR"
else
  DEFAULT_SEED_DIR="$REPO_ROOT/persistent"
fi

[[ -d "$DEFAULT_SEED_DIR" ]] || { echo "Seed directory not found: $DEFAULT_SEED_DIR" >&2; exit 1; }

publish_profile_artifacts() {
  local profile="$1"
  local iso_path="$WORKDIR/install-${profile}.iso"
  local native_img_path="$WORKDIR/install-${profile}.img"
  local native_minimal_img_path="$WORKDIR/install-${profile}-minimal.img"

  if [[ "$PUBLISH_ENABLED" != "1" && "$PUBLISH_ENABLED" != "true" && "$PUBLISH_ENABLED" != "yes" ]]; then
    echo "Skipping publish for profile '$profile' (PUBLISH_ENABLED=$PUBLISH_ENABLED)"
    return
  fi

  mkdir -p "$PUBLISH_DIR"
  cp "$iso_path" "$PUBLISH_DIR/"
  cp "$native_img_path" "$PUBLISH_DIR/"
  cp "$native_minimal_img_path" "$PUBLISH_DIR/"

  echo "Published ISO: $PUBLISH_DIR/$(basename "$iso_path")"
  echo "Published IMG: $PUBLISH_DIR/$(basename "$native_img_path")"
  echo "Published Minimal IMG: $PUBLISH_DIR/$(basename "$native_minimal_img_path")"
}

build_profile() {
  local profile="$1"
  local mode="$2"
  local iso_path="$WORKDIR/install-${profile}.iso"
  local native_img_path="$WORKDIR/install-${profile}.img"
  local native_minimal_img_path="$WORKDIR/install-${profile}-minimal.img"
  local force_args=()
  local persist_args=()

  if [[ "$FORCE" -eq 1 ]]; then
    force_args+=(--force)
  fi
  if [[ -n "$PERSIST_FS" ]]; then
    persist_args+=(--persist-fs "$PERSIST_FS")
  fi

  echo
  echo "=== Building ${profile} ISO (${mode}) ==="
  build_iso_args=("$mode")
  if [[ "$CLEAN_BUILD" -eq 1 && "$mode" == "full" ]]; then
    build_iso_args+=(--clean)
  fi
  if [[ -n "$PERSIST_FS" ]]; then
    build_iso_args+=(--persist-fs "$PERSIST_FS")
  fi
  if [[ "$MENU_BACKEND" != "auto" ]]; then
    build_iso_args+=(--menu-backend "$MENU_BACKEND")
  fi
  PUBLISH_ISO="$iso_path" "$SCRIPT_DIR/build-iso.sh" "${build_iso_args[@]}" --menu-ui "$MENU_UI"

  echo
  echo "=== Building ${profile} image (seeded) ==="
  echo "Using seed directory: $DEFAULT_SEED_DIR"
  bash "$SCRIPT_DIR/build-usb-native.sh" \
    --iso "$iso_path" \
    --output "$native_img_path" \
    --size "$IMAGE_SIZE" \
    --seed-dir "$DEFAULT_SEED_DIR" \
    "${persist_args[@]}" \
    "${force_args[@]}"
  echo "Built image: $native_img_path"

  echo
  echo "=== Building ${profile} minimal image (no persistence partition; in-memory runtime data) ==="
  bash "$SCRIPT_DIR/build-usb-native.sh" \
    --iso "$iso_path" \
    --output "$native_minimal_img_path" \
    --size "$IMAGE_SIZE" \
    --efi-mib 128 \
    --root-mib 0 \
    --no-persist \
    "${force_args[@]}"
  echo "Built minimal image: $native_minimal_img_path"

  publish_profile_artifacts "$profile"
}

build_profile "user" "$FIRST_MODE"

echo
echo "Done. Requested install image build(s) completed."
