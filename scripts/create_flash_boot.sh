#!/bin/bash
# -----------------------------------------------------------------------------
# create_flash_boot
#
# Overview:
#   Prepares a USB flash drive for unRAID by creating one FAT32 partition
#   labeled UNRAID, extracting the selected unRAID zip payload, and running the
#   restored make_bootable_linux script.
#
# Accepted arguments:
#   $1  Target disk device (optional), for example: sdb or /dev/sdb
#       If omitted, the script prompts interactively for a USB disk.
#
# Copyright (c) 2026, Lime Technology, Inc. (Limetech)
# -----------------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi

set -euo pipefail

UI_MODE="${UI_MODE:-text}"
ui_backend="text"
TARGET_DISK_ARG=""

while (($#)); do
    case "$1" in
        --ui)
            [[ $# -ge 2 ]] || { echo "Missing value for --ui" >&2; exit 1; }
            UI_MODE="$2"
            shift 2
            ;;
        *)
            if [[ -z "$TARGET_DISK_ARG" ]]; then
                TARGET_DISK_ARG="${1#/dev/}"
                shift
            else
                echo "Unknown argument: $1" >&2
                exit 1
            fi
            ;;
    esac
done

case "$UI_MODE" in
    text|gui) ;;
    *)
        echo "--ui must be 'text' or 'gui'" >&2
        exit 1
        ;;
esac

detect_ui_backend() {
    local preferred="${MENU_BACKEND:-}"

    if [[ "$UI_MODE" != "gui" ]]; then
        ui_backend="text"
        return
    fi

    case "${preferred,,}" in
        whiptail)
            if command -v whiptail >/dev/null 2>&1; then
                ui_backend="whiptail"
                return
            fi
            ;;
        dialog)
            if command -v dialog >/dev/null 2>&1; then
                ui_backend="dialog"
                return
            fi
            ;;
        text)
            ui_backend="text"
            return
            ;;
        "")
            ;;
        *)
            echo "Ignoring unknown MENU_BACKEND '$preferred' (expected: whiptail|dialog|text)." >&2
            ;;
    esac

    if command -v whiptail >/dev/null 2>&1; then
        ui_backend="whiptail"
        return
    fi
    if command -v dialog >/dev/null 2>&1; then
        ui_backend="dialog"
        return
    fi
    ui_backend="text"
}

ui_has_tty() {
    [[ -e /dev/tty ]] || return 1
    : </dev/tty >/dev/tty 2>/dev/null
}

run_ui_cmd() {
    if ui_has_tty; then
        "$@" </dev/tty >/dev/tty 2>/dev/tty
    else
        "$@"
    fi
}

ui_prompt() {
    local title="$1" prompt="$2" default_value="${3:-}"

    case "$ui_backend" in
        whiptail)
            whiptail --title "$title" --inputbox "$prompt" 12 90 "$default_value" 3>&1 1>&2 2>&3 || true
            ;;
        dialog)
            local out
            out="$(dialog --title "$title" --inputbox "$prompt" 12 90 "$default_value" 3>&1 1>&2 2>&3)" || true
            clear
            printf '%s\n' "$out"
            ;;
        *)
            local ans
            if [[ -n "$default_value" ]]; then
                read -r -p "$prompt (default: $default_value): " ans || true
                printf '%s\n' "${ans:-$default_value}"
            else
                read -r -p "$prompt: " ans || true
                printf '%s\n' "$ans"
            fi
            ;;
    esac
}

ui_menu_select() {
    local title="$1" prompt="$2"
    shift 2

    case "$ui_backend" in
        whiptail)
            whiptail --title "$title" --menu "$prompt" 22 110 12 "$@" 3>&1 1>&2 2>&3
            ;;
        dialog)
            local out
            out="$(dialog --title "$title" --menu "$prompt" 22 110 12 "$@" 3>&1 1>&2 2>&3)"
            local rc=$?
            clear
            [[ $rc -eq 0 ]] || return "$rc"
            printf '%s\n' "$out"
            ;;
        *)
            return 1
            ;;
    esac
}

ui_msg() {
    local title="$1" message="$2"

    case "$ui_backend" in
        whiptail)
            run_ui_cmd whiptail --title "$title" --msgbox "$message" 16 100
            ;;
        dialog)
            run_ui_cmd dialog --title "$title" --msgbox "$message" 16 100
            clear
            ;;
        *)
            echo "$message"
            ;;
    esac
}

ui_infobox() {
    local title="$1" message="$2"

    case "$ui_backend" in
        whiptail)
            run_ui_cmd whiptail --title "$title" --infobox "$message" 12 100
            ;;
        dialog)
            run_ui_cmd dialog --title "$title" --infobox "$message" 12 100
            ;;
        *)
            ;;
    esac
}

ui_view_log() {
    local title="$1" log_file="$2"

    case "$ui_backend" in
        whiptail)
            run_ui_cmd whiptail --title "$title" --scrolltext --textbox "$log_file" 30 120
            ;;
        dialog)
            run_ui_cmd dialog --title "$title" --textbox "$log_file" 30 120
            clear
            ;;
        *)
            cat "$log_file"
            ;;
    esac
}

RUN_LOG_FILE=""
STEP_COUNT=0
TOTAL_STEPS=8

init_run_log() {
    RUN_LOG_FILE="$(mktemp /tmp/create-flash-boot.XXXXXX.log)"
}

append_run_log() {
    [[ -n "$RUN_LOG_FILE" ]] || init_run_log
    printf '%s\n' "$*" >>"$RUN_LOG_FILE"
}

status_msg() {
    local message="$*"
    if [[ "$ui_backend" != "text" ]]; then
        ui_infobox "Flash Boot Status" "$message"
        append_run_log "$message"
    else
        echo "$message"
    fi
}

log_msg() {
    local message="$*"
    if [[ "$ui_backend" != "text" ]]; then
        append_run_log "$message"
    else
        echo "$message"
    fi
}

error_msg() {
    local message="$*"
    if [[ "$ui_backend" != "text" ]]; then
        append_run_log "$message"
        ui_msg "Flash Boot Error" "$message"
    else
        echo "$message"
    fi
}

run_operation() {
    if [[ "$ui_backend" != "text" ]]; then
        "$@" >>"$RUN_LOG_FILE" 2>&1
    else
        "$@"
    fi
}

step_update() {
    local step_text="$1"
    STEP_COUNT=$((STEP_COUNT + 1))

    if [[ "$ui_backend" != "text" ]]; then
        ui_infobox "Flash Boot Progress" "Step ${STEP_COUNT}/${TOTAL_STEPS}\n${step_text}"
        printf '==> [%s/%s] %s\n' "$STEP_COUNT" "$TOTAL_STEPS" "$step_text" >>"$RUN_LOG_FILE"
        return
    fi

    echo
    echo "==> [${STEP_COUNT}/${TOTAL_STEPS}] ${step_text}"
}

confirm() {
    local prompt="$1" default="${2:-n}" ans hint

    case "$ui_backend" in
        whiptail)
            if [[ "$default" == "n" ]]; then
                run_ui_cmd whiptail --title "Confirm" --defaultno --yesno "$prompt" 12 90
            else
                run_ui_cmd whiptail --title "Confirm" --yesno "$prompt" 12 90
            fi
            return $?
            ;;
        dialog)
            if [[ "$default" == "n" ]]; then
                run_ui_cmd dialog --title "Confirm" --defaultno --yesno "$prompt" 12 90
            else
                run_ui_cmd dialog --title "Confirm" --yesno "$prompt" 12 90
            fi
            local rc=$?
            clear
            return "$rc"
            ;;
    esac

    if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    read -r -p "${prompt} ${hint} (default: ${default}) : " ans || true
    ans="${ans,,}"
    [[ -z "$ans" ]] && ans="$default"
    [[ "$ans" == "y" || "$ans" == "yes" ]]
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        error_msg "ERROR: missing required command: $cmd"
        exit 1
    }
}

partition1_path() {
    local disk="$1"
    if [[ "$disk" =~ [0-9]$ ]]; then
        printf '%sp1\n' "$disk"
    else
        printf '%s1\n' "$disk"
    fi
}

find_make_bootable_script() {
    local mount_dir="$1"
    local candidate

    for candidate in \
        "$mount_dir/make_bootable_linux" \
        "$mount_dir/make_bootable_linux.sh" \
        "$mount_dir/syslinux/make_bootable_linux" \
        "$mount_dir/syslinux/make_bootable_linux.sh"
    do
        [[ -f "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done

    return 1
}

detect_ui_backend
init_run_log

if [[ "$(id -u)" != "0" ]]; then
    error_msg "ERROR: create_flash_boot.sh must run as root."
    exit 1
fi

require_cmd lsblk
require_cmd awk
require_cmd parted
require_cmd mkfs.vfat
require_cmd unzip
require_cmd wipefs
require_cmd partprobe
require_cmd udevadm
require_cmd mount
require_cmd umount
require_cmd sync
require_cmd id

ZIP_ROOT="${PERSISTENT_ROOT:-/mnt/persist}"
ZIP_DIR="${PERSISTENT_ZIP_DIR:-${ZIP_ROOT}/zips}"
if [[ ! -d "$ZIP_DIR" && -d "${ZIP_ROOT}/zip" ]]; then
    ZIP_DIR="${ZIP_ROOT}/zip"
fi

if [[ "${PERSIST_READY:-0}" != "1" ]]; then
    if [[ -d /run && -w /run ]]; then
        ZIP_DIR="/run/onboarding-zips"
    else
        ZIP_DIR="/tmp/onboarding-zips"
    fi

    mkdir -p "$ZIP_DIR" || {
        error_msg "ERROR: unable to create in-memory ZIP path: ${ZIP_DIR}"
        exit 1
    }

    status_msg "Persistent storage is not mounted. Using in-memory ZIP path: ${ZIP_DIR}"
fi

if compgen -G "${ZIP_DIR}/unRAIDServer-*-x86_64.zip" > /dev/null; then
    ZIP_FILE="$(find "$ZIP_DIR" -maxdepth 1 -type f -name 'unRAIDServer-*-x86_64.zip' -print | sort -V | tail -n1)"
else
    error_msg "ERROR: no unRAIDServer zip files found in ${ZIP_DIR}"
    exit 1
fi

status_msg "Flash boot image tool"
status_msg "Using zip file: $ZIP_FILE"

VERSION_CHECK_LIB="${VERSION_CHECK_LIB:-/boot/install/version_check.sh}"
if [[ -f "$VERSION_CHECK_LIB" ]]; then
    # shellcheck disable=SC1090
    . "$VERSION_CHECK_LIB"
    zip_warning="$(zip_update_warning "$ZIP_FILE" 2>/dev/null || true)"
    if [[ -n "$zip_warning" ]]; then
        ui_msg "ZIP Update Available" "$zip_warning"
    fi
fi

if [[ -n "$TARGET_DISK_ARG" ]]; then
    TARGET_DISK="$TARGET_DISK_ARG"
else
    disk_list_file="$(mktemp)"
    lsblk -d -n -o NAME,SIZE,MODEL,TRAN --raw | awk '{
        name=$1; size=$2; tran=$NF;
        model="";
        for (i=3; i<NF; i++) {
            model = model (model=="" ? "" : " ") $i;
        }
        if (tolower(tran) == "usb") {
            printf "%s\t%s\t%s\t%s\n", name, size, model, tran;
        }
    }' > "$disk_list_file"

    if [[ "$ui_backend" == "text" ]]; then
        echo "Available USB disks (boot media can be reused):"
        printf "%-8s %-8s %-30s %-8s\n" "NAME" "SIZE" "MODEL" "TRAN"
    fi

    menu_args=()
    while IFS=$'\t' read -r name size model tran; do
        [[ -n "$name" ]] || continue
        model="${model//\\x20/ }"
        [[ -n "$model" ]] || model="n/a"
        [[ -n "$tran" && "$tran" != "-" ]] || tran="n/a"

        if [[ "$ui_backend" == "text" ]]; then
            printf "%-8s %-8s %-30s %-8s\n" "$name" "$size" "$model" "$tran"
        fi

        menu_args+=("$name" "$size | $model | $tran")
    done < "$disk_list_file"
    rm -f "$disk_list_file"

    if [[ ${#menu_args[@]} -eq 0 ]]; then
        error_msg "ERROR: no USB disks found."
        exit 1
    fi

    echo
    if [[ "$ui_backend" != "text" ]]; then
        TARGET_DISK="$(ui_menu_select "Target USB Disk" "Select target USB disk" "${menu_args[@]}")" || {
            log_msg "Aborted."
            exit 1
        }
    else
        TARGET_DISK="$(ui_prompt "Target USB Disk" "Enter target disk (example: sdb)")"
    fi
fi

TARGET="/dev/$TARGET_DISK"
TARGET_PART1="$(partition1_path "$TARGET")"

if [[ ! -b "$TARGET" ]]; then
    error_msg "ERROR: $TARGET does not exist."
    exit 1
fi

if [[ "$(lsblk -dn -o TYPE "$TARGET" 2>/dev/null || true)" != "disk" ]]; then
    error_msg "ERROR: $TARGET is not a whole disk device."
    exit 1
fi

if [[ "$ui_backend" != "text" ]]; then
    if ! confirm "ALL DATA on $TARGET will be destroyed. Continue?" "n"; then
        log_msg "Aborted."
        exit 1
    fi
else
    CONFIRM="$(ui_prompt "Destructive Action" "ALL DATA on $TARGET will be destroyed. Type YES to continue")"
    [[ "$CONFIRM" != "YES" ]] && { echo "Aborted."; exit 1; }
fi

mount_dir=""
cleanup() {
    if [[ -n "$mount_dir" && -d "$mount_dir" ]]; then
        run_operation umount "$mount_dir" || true
        run_operation rmdir "$mount_dir" || true
    fi
}
trap cleanup EXIT

step_update "Unmounting existing target partitions"
lsblk_parts_file="$(mktemp)"
lsblk -nrpo NAME,MOUNTPOINT "$TARGET" | tail -n +2 > "$lsblk_parts_file"
while read -r part_path mount_path; do
    [[ -n "$part_path" ]] || continue
    if [[ -n "${mount_path:-}" ]]; then
        run_operation umount "$part_path" || run_operation umount -l "$part_path" || true
    fi
done < "$lsblk_parts_file"
rm -f "$lsblk_parts_file"

step_update "Wiping target signatures"
run_operation wipefs -a "$TARGET"

step_update "Creating single FAT32 UNRAID partition"
run_operation parted -s "$TARGET" mklabel msdos
run_operation parted -s "$TARGET" mkpart primary fat32 1MiB 100%
run_operation parted -s "$TARGET" set 1 boot on
run_operation partprobe "$TARGET" || true
run_operation udevadm settle || true

if [[ ! -b "$TARGET_PART1" ]]; then
    error_msg "ERROR: expected partition not found: $TARGET_PART1"
    exit 1
fi

step_update "Formatting partition as FAT32"
run_operation mkfs.vfat -F 32 -n UNRAID "$TARGET_PART1"

step_update "Mounting UNRAID partition"
mount_dir="$(mktemp -d /tmp/create-flash-boot.XXXXXX)"
run_operation mount "$TARGET_PART1" "$mount_dir"

step_update "Extracting unRAID zip payload"
run_operation unzip -o "$ZIP_FILE" -d "$mount_dir"
run_operation sync

step_update "Running make_bootable_linux"
MAKE_BOOTABLE="$(find_make_bootable_script "$mount_dir" || true)"
if [[ -z "$MAKE_BOOTABLE" ]]; then
    error_msg "ERROR: make_bootable_linux not found in extracted zip payload."
    exit 1
fi

run_operation chmod +x "$MAKE_BOOTABLE" || true
if confirm "Enable UEFI boot mode for this flash drive?" "y"; then
    UEFI_ANSWER="Y"
else
    UEFI_ANSWER="N"
fi

if [[ "$ui_backend" != "text" ]]; then
    printf '%s\n' "$UEFI_ANSWER" | bash "$MAKE_BOOTABLE" >>"$RUN_LOG_FILE" 2>&1
else
    printf '%s\n' "$UEFI_ANSWER" | bash "$MAKE_BOOTABLE"
fi
run_operation sync

step_update "Finalizing"
run_operation umount "$mount_dir"
run_operation rmdir "$mount_dir"
mount_dir=""

status_msg "Flash boot image creation complete"
log_msg "Operation log: $RUN_LOG_FILE"

if [[ "$ui_backend" != "text" ]]; then
    ui_msg "Flash Boot Complete" "UNRAID flash drive creation complete."
fi

if confirm "View full operation log now?" "n"; then
    ui_view_log "Flash Boot Full Log" "$RUN_LOG_FILE"
fi
