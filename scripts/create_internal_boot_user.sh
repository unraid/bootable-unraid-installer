#!/bin/bash
# -----------------------------------------------------------------------------
# create_internal_boot
#
# Overview:
#   Prepares an internal boot device by partitioning the target disk, unpacking
#   the boot zip to /boot-transfer, validating SHA256 files, and writing
#   user boot media data.
#
# Accepted arguments:
#   $1 [$2]  Target disk device(s) (optional), for example: nvme1n1 or /dev/nvme1n1
#            If omitted, the script prompts interactively for disk selection.
#   --size SIZE_MIB (optional), for example: 8192
#       Boot pool target size in MiB; use 0 for dedicated boot pool (default: 8192).
#
# Copyright (c) 2026, Lime Technology, Inc. (Limetech)
# -----------------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi

set -euo pipefail

UI_MODE="${UI_MODE:-text}"
ui_backend="text"
TARGET_DISK_ARG_1=""
TARGET_DISK_ARG_2=""
TARGET_DISK=""
TARGET_DISK_2=""
SIZE="${INTERNAL_BOOT_SIZE_MIB:-8192}"
DEFAULT_BOOT_SIZE_MIB=8192
MIN_DATA_PART_MIB=1
REQUESTED_DEDICATED_SIZE=0
BOOT_POOL_NAME="${BOOT_POOL_NAME:-boot}"
BOOT_DEVICE_COUNT=1
RESTORE_BACKUP=""

while (($#)); do
    case "$1" in
        --ui)
            [[ $# -ge 2 ]] || { echo "Missing value for --ui" >&2; exit 1; }
            UI_MODE="$2"
            shift 2
            ;;
        --size)
            [[ $# -ge 2 ]] || { echo "Missing value for --size" >&2; exit 1; }
            SIZE="$2"
            shift 2
            ;;
        --restore-backup)
            [[ $# -ge 2 ]] || { echo "Missing value for --restore-backup" >&2; exit 1; }
            RESTORE_BACKUP="$2"
            shift 2
            ;;
        *)
            if [[ -z "$TARGET_DISK_ARG_1" ]]; then
                TARGET_DISK_ARG_1="${1#/dev/}"
                shift
            elif [[ -z "$TARGET_DISK_ARG_2" ]]; then
                TARGET_DISK_ARG_2="${1#/dev/}"
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

[[ "$SIZE" =~ ^[0-9]+$ ]] || { echo "--size must be an integer MiB value" >&2; exit 1; }
if (( SIZE != 0 && SIZE < 1024 )); then
    echo "--size must be 0 (dedicated) or at least 1024 MiB" >&2
    exit 1
fi
if (( SIZE == 0 )); then
    REQUESTED_DEDICATED_SIZE=1
fi

normalize_disk_name() {
    local raw="${1:-}"

    raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
    raw="${raw#/dev/}"

    printf '%s\n' "$raw"
}

disk_path_from_name() {
    local disk_name=""

    disk_name="$(normalize_disk_name "$1")"
    printf '/dev/%s\n' "$disk_name"
}

TARGET_DISK_ARG_1="$(normalize_disk_name "$TARGET_DISK_ARG_1")"
TARGET_DISK_ARG_2="$(normalize_disk_name "$TARGET_DISK_ARG_2")"

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
            whiptail --title "$title" --inputbox "$prompt" 12 80 "$default_value" 3>&1 1>&2 2>&3 || true
            ;;
        dialog)
            local out
            out="$(dialog --title "$title" --inputbox "$prompt" 12 80 "$default_value" 3>&1 1>&2 2>&3)" || true
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
            whiptail --title "$title" --menu "$prompt" 22 100 12 "$@" 3>&1 1>&2 2>&3
            ;;
        dialog)
            local out
            out="$(dialog --title "$title" --menu "$prompt" 22 100 12 "$@" 3>&1 1>&2 2>&3)"
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

prompt_boot_device_count() {
    local choice=""

    if [[ -n "$TARGET_DISK_ARG_2" ]]; then
        BOOT_DEVICE_COUNT=2
        return 0
    fi
    if [[ -n "$TARGET_DISK_ARG_1" ]]; then
        BOOT_DEVICE_COUNT=1
        return 0
    fi

    if [[ "$ui_backend" != "text" ]]; then
        choice="$(ui_menu_select "Boot Device Count" "How many boot devices should be created?" \
            1 "Single disk" \
            2 "Two disks (mirrored)")" || return 1
    else
        read -r -p "How many boot devices should be created? [1-2] (default: 1): " choice || true
        choice="${choice:-1}"
    fi

    case "$choice" in
        1|2)
            BOOT_DEVICE_COUNT="$choice"
            ;;
        *)
            if [[ "$ui_backend" != "text" ]]; then
                ui_msg "Invalid Selection" "Choose 1 or 2 devices."
            else
                echo "Invalid selection. Choose 1 or 2." >&2
            fi
            return 1
            ;;
    esac
}

select_target_disk() {
    local title="$1"
    local prompt="$2"
    local exclude_disk="${3:-}"
    local exclude_path=""
    local selected=""
    local selected_disk=""
    local selected_path=""
    local disk_list_file=""
    local menu_args=()

    if [[ -n "$exclude_disk" ]]; then
        exclude_path="$(disk_path_from_name "$exclude_disk")"
    fi

    if [[ "$ui_backend" == "text" ]]; then
        echo "Available disks:"
        printf "%-8s %-8s %-30s %-8s %s\n" "NAME" "SIZE" "MODEL" "TRAN" "ID"
    fi

    disk_list_file="$(mktemp)"
    lsblk -d -n -o NAME,SIZE,MODEL,TRAN --raw | awk '{
        name=$1; size=$2; tran=$NF;
        model="";
        for (i=3; i<NF; i++) {
            model = model (model=="" ? "" : " ") $i;
        }
        printf "%s\t%s\t%s\t%s\n", name, size, model, tran;
    }' > "$disk_list_file"

    while IFS=$'\t' read -r name size model tran; do
        [[ -n "$name" ]] || continue
        model="${model//\\x20/ }"
        [[ -n "$model" ]] || model="n/a"
        [[ -n "$tran" && "$tran" != "-" ]] || tran="n/a"
        disk_path="/dev/$name"
        if [[ -n "$ONBOARDING_BOOT_DISK" && "$disk_path" == "$ONBOARDING_BOOT_DISK" ]]; then
            continue
        fi
        if [[ -n "$exclude_path" && "$disk_path" == "$exclude_path" ]]; then
            continue
        fi
        disk_id="$(resolve_disk_id "$disk_path" || true)"
        [[ -n "$disk_id" ]] || disk_id="n/a"
        if [[ "$ui_backend" == "text" ]]; then
            printf "%-8s %-8s %-30s %-8s %s\n" "$name" "$size" "$model" "$tran" "$disk_id"
        fi
        menu_args+=("$name" "$size | $model | $tran | $disk_id")
    done < "$disk_list_file"
    rm -f "$disk_list_file"

    echo
    if [[ "$ui_backend" != "text" && ${#menu_args[@]} -gt 0 ]]; then
        selected="$(ui_menu_select "$title" "$prompt" "${menu_args[@]}")" || return 1
    else
        selected="$(ui_prompt "$title" "Enter target disk (example: nvme1n1)")"
    fi

    selected_disk="$(normalize_disk_name "$selected")"
    selected_path="$(disk_path_from_name "$selected_disk")"

    if [[ -n "$exclude_path" && "$selected_path" == "$exclude_path" ]]; then
        if [[ "$ui_backend" != "text" ]]; then
            ui_msg "Invalid Selection" "Choose a different disk from the first selected device ($exclude_path)."
        else
            echo "Invalid selection. Choose a different disk from $exclude_path." >&2
        fi
        return 1
    fi

    printf '%s\n' "$selected_disk"
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
TOTAL_STEPS=9

init_run_log() {
    RUN_LOG_FILE="$(mktemp /tmp/create-internal-boot-user.XXXXXX.log)"
}

show_failure_log_on_exit() {
    local rc=$?

    if (( rc == 0 )); then
        return
    fi

    if [[ -z "${RUN_LOG_FILE:-}" || ! -f "$RUN_LOG_FILE" ]]; then
        return
    fi

    append_run_log "ERROR: create_internal_boot_user failed (exit code: $rc)"

    if [[ "$ui_backend" != "text" ]]; then
        ui_msg "Internal Boot Error" "Create internal boot failed. Showing operation log."
        ui_view_log "Internal Boot Error Log" "$RUN_LOG_FILE" || true
    else
        echo
        echo "Create internal boot failed. Operation log: $RUN_LOG_FILE"
        cat "$RUN_LOG_FILE" || true
    fi
}

append_run_log() {
    [[ -n "$RUN_LOG_FILE" ]] || init_run_log
    printf '%s\n' "$*" >>"$RUN_LOG_FILE"
}

status_msg() {
    local message="$*"
    if [[ "$ui_backend" != "text" ]]; then
        ui_infobox "Internal Boot Status" "$message"
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
        ui_msg "Internal Boot Error" "$message"
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
        ui_infobox "Internal Boot Progress" "Step ${STEP_COUNT}/${TOTAL_STEPS}\n${step_text}"
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
                run_ui_cmd whiptail --title "Confirm" --defaultno --yesno "$prompt" 12 80
            else
                run_ui_cmd whiptail --title "Confirm" --yesno "$prompt" 12 80
            fi
            return $?
            ;;
        dialog)
            if [[ "$default" == "n" ]]; then
                run_ui_cmd dialog --title "Confirm" --defaultno --yesno "$prompt" 12 80
            else
                run_ui_cmd dialog --title "Confirm" --yesno "$prompt" 12 80
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

prompt_default() {
  local prompt="$1" def="$2" ans
  read -r -p "${prompt} (default: ${def}) : " ans || true
  echo "${ans:-$def}"
}

is_valid_pool_name() {
    local pool_name="$1"

    [[ -n "$pool_name" ]] || return 1
    [[ "$pool_name" == "${pool_name,,}" ]] || return 1
    [[ "$pool_name" =~ ^[a-z][a-z0-9_-]*$ ]]
}

prompt_boot_pool_name() {
    local entered

    while true; do
        entered="$(ui_prompt "Boot Pool Name" "Enter pool name (lowercase letters/numbers, '-' or '_')" "$BOOT_POOL_NAME")"
        entered="${entered//[[:space:]]/}"
        [[ -n "$entered" ]] || entered="$BOOT_POOL_NAME"

        if is_valid_pool_name "$entered"; then
            BOOT_POOL_NAME="$entered"
            return 0
        fi

        if [[ "$ui_backend" != "text" ]]; then
            ui_msg "Invalid Pool Name" "Pool name must be lowercase and start with a letter."
        else
            echo "Invalid pool name. Use lowercase and start with a letter."
        fi
    done
}

prompt_size_for_small_disk() {
    local disk_size_mib="$1"
    local available_size_mib dedicated_size_mib choice custom_size

    available_size_mib=$(( disk_size_mib * 48 / 100 ))
    dedicated_size_mib=$(( disk_size_mib - MIN_DATA_PART_MIB ))

    (( available_size_mib < 1024 )) && available_size_mib=1024
    (( dedicated_size_mib < 1 )) && dedicated_size_mib=1
    (( available_size_mib > dedicated_size_mib )) && available_size_mib="$dedicated_size_mib"

    while true; do
        if [[ "$ui_backend" != "text" ]]; then
            choice="$(ui_menu_select "Boot Pool Size" "Disk is ${disk_size_mib} MiB (< default ${DEFAULT_BOOT_SIZE_MIB} MiB). Choose size." \
                A "Available (48%): ${available_size_mib} MiB" \
                B "Dedicated (reserve ${MIN_DATA_PART_MIB} MiB for p4)" \
                C "Custom")" || return 1
        else
            echo "Disk size ${disk_size_mib} MiB is smaller than default ${DEFAULT_BOOT_SIZE_MIB} MiB."
            echo "A) Available (48%): ${available_size_mib} MiB"
            echo "B) Dedicated (reserve ${MIN_DATA_PART_MIB} MiB for p4)"
            echo "C) Custom"
            read -r -p "Select boot pool size option [A-C]: " choice || true
            choice="${choice^^}"
        fi

        case "$choice" in
            A)
                SIZE="$available_size_mib"
                return 0
                ;;
            B)
                SIZE="$dedicated_size_mib"
                return 0
                ;;
            C)
                custom_size="$(ui_prompt "Custom Boot Size" "Enter size in MiB (0 for dedicated, >=1024 and <=${dedicated_size_mib})" "$available_size_mib")"
                custom_size="${custom_size//[[:space:]]/}"
                if [[ "$custom_size" =~ ^[0-9]+$ ]] && (( custom_size == 0 || (custom_size >= 1024 && custom_size <= dedicated_size_mib) )); then
                    if (( custom_size == 0 )); then
                        SIZE="$dedicated_size_mib"
                    else
                        SIZE="$custom_size"
                    fi
                    return 0
                fi
                if [[ "$ui_backend" != "text" ]]; then
                    ui_msg "Invalid Size" "Enter 0 (dedicated) or 1024..${dedicated_size_mib} MiB."
                else
                    echo "Invalid size. Enter 0 (dedicated) or 1024..${dedicated_size_mib} MiB."
                fi
                ;;
            *)
                if [[ "$ui_backend" == "text" ]]; then
                    echo "Invalid option."
                fi
                ;;
        esac
    done
}

resolve_disk_id() {
    local disk="$1"
    local id=""
    local link resolved
    local transport=""
    local model=""
    local short_serial=""

    sanitize_disk_id() {
        local raw="$1"

        # Keep USB IDs exactly as discovered.
        if [[ "$transport" == "usb" ]]; then
            printf '%s\n' "$raw"
            return 0
        fi

        printf '%s\n' "$raw" | sed -E 's/[[:space:]]+/_/g; s/[^[:alnum:]_.-]/_/g; s/^_+//; s/_+$//'
    }

    transport="$(lsblk -dn -o TRAN "$disk" 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n1 || true)"
    if [[ "$transport" != "usb" ]]; then
        model="$(lsblk -dn -o MODEL "$disk" 2>/dev/null | head -n1 || true)"
        model="${model//\\x20/ }"
        model="$(sanitize_disk_id "$model")"

        if command -v udevadm >/dev/null 2>&1; then
            short_serial="$(udevadm info --query=property --name "$disk" 2>/dev/null | awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}')"
        fi
        if [[ -z "$short_serial" ]]; then
            short_serial="$(lsblk -dn -o SERIAL "$disk" 2>/dev/null | head -n1 || true)"
        fi
        short_serial="${short_serial//\\x20/ }"
        short_serial="$(sanitize_disk_id "$short_serial")"

        if [[ -n "$model" && -n "$short_serial" ]]; then
            id="${model}_${short_serial}"
            id="$(sanitize_disk_id "$id")"
            printf '%s\n' "$id"
            return 0
        fi
    fi

    if command -v udevadm >/dev/null 2>&1; then
        id="$(udevadm info --query=property --name "$disk" 2>/dev/null | awk -F= '/^ID_SERIAL=/{print $2; exit}')"
        if [[ -n "$id" ]]; then
            id="$(sanitize_disk_id "$id")"
            printf '%s\n' "$id"
            return 0
        fi
        id="$(udevadm info --query=property --name "$disk" 2>/dev/null | awk -F= '/^ID_WWN=/{print $2; exit}')"
        if [[ -n "$id" ]]; then
            id="$(sanitize_disk_id "$id")"
            printf '%s\n' "$id"
            return 0
        fi
    fi

    for link in /dev/disk/by-id/*; do
        [[ -e "$link" ]] || continue
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        if [[ "$resolved" == "$disk" ]]; then
            id="$(basename "$link")"
            id="$(sanitize_disk_id "$id")"
            printf '%s\n' "$id"
            return 0
        fi
    done

    id="$(lsblk -dn -o WWN,SERIAL "$disk" 2>/dev/null | awk '{print $1; exit}' || true)"
    id="$(sanitize_disk_id "$id")"
    if [[ -n "$id" && "$id" != "-" ]]; then
        printf '%s\n' "$id"
        return 0
    fi

    return 1
}

detect_onboarding_boot_disk() {
    local boot_part=""
    local boot_disk=""

    if [[ -e /dev/disk/by-label/INSTALLER ]]; then
        boot_part="$(readlink -f /dev/disk/by-label/INSTALLER 2>/dev/null || true)"
    elif [[ -e /dev/disk/by-label/ONBOARDING ]]; then
        boot_part="$(readlink -f /dev/disk/by-label/ONBOARDING 2>/dev/null || true)"
    elif command -v blkid >/dev/null 2>&1; then
        boot_part="$(blkid -L INSTALLER 2>/dev/null || true)"
        if [[ -z "$boot_part" ]]; then
            boot_part="$(blkid -L ONBOARDING 2>/dev/null || true)"
        fi
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
    esac

    if [[ -n "$boot_disk" && -b "$boot_disk" ]]; then
        printf '%s\n' "$boot_disk"
    fi
}

ensure_zfs_runtime() {
    local running_kernel=""

    if ! command -v zpool >/dev/null 2>&1 || ! command -v zfs >/dev/null 2>&1; then
        error_msg "ERROR: ZFS userspace tools are missing (zpool/zfs not found)."
        log_msg "Rebuild the Unraid ISO Installer image with full mode and boot from the updated media."
        exit 1
    fi

    if ! command -v modprobe >/dev/null 2>&1; then
        error_msg "ERROR: modprobe is not available; cannot load ZFS kernel modules."
        exit 1
    fi

    if ! modprobe zfs >/dev/null 2>&1; then
        running_kernel="$(uname -r 2>/dev/null || true)"
        error_msg "ERROR: unable to load ZFS kernel module (modprobe zfs failed)."
        if [[ -n "$running_kernel" ]]; then
            log_msg "Running kernel: $running_kernel"
            log_msg "Expected module tree: /lib/modules/$running_kernel"
            if [[ -d "/lib/modules/$running_kernel" ]]; then
                log_msg "Found /lib/modules/$running_kernel but zfs.ko could not be loaded."
            else
                log_msg "Missing /lib/modules/$running_kernel (ZFS modules are not installed for this kernel)."
            fi
        fi
        if [[ -d /lib/modules ]]; then
            log_msg "Available module trees under /lib/modules:"
            ls -1 /lib/modules 2>/dev/null || true
        else
            log_msg "Directory /lib/modules is missing."
        fi
        log_msg "Rebuild using full mode and ensure the flashed image matches the latest build artifacts."
        exit 1
    fi
}

detect_ui_backend
init_run_log
trap show_failure_log_on_exit EXIT

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

if [[ -n "$RESTORE_BACKUP" ]]; then
    ZIP_FILE="$RESTORE_BACKUP"
    if [[ ! -f "$ZIP_FILE" ]]; then
        error_msg "ERROR: restore backup does not exist: $ZIP_FILE"
        exit 1
    fi
    if ! unzip -Z1 "$ZIP_FILE" | grep -qx 'config/' || ! unzip -Z1 "$ZIP_FILE" | grep -qx 'bzimage'; then
        error_msg "ERROR: restore backup must contain config/ and bzimage."
        exit 1
    fi
    if unzip -Z1 "$ZIP_FILE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
        error_msg "ERROR: restore backup contains unsafe paths."
        exit 1
    fi
    status_msg "Using restore backup: $ZIP_FILE"
elif compgen -G "${ZIP_DIR}/unRAIDServer-*-x86_64.zip" > /dev/null; then
    ZIP_FILE="$(find "$ZIP_DIR" -maxdepth 1 -type f -name 'unRAIDServer-*-x86_64.zip' -print | sort -V | tail -n1)"
else
    error_msg "ERROR: no unRAIDServer zip files found in ${ZIP_DIR}"
    exit 1
fi

ensure_zfs_runtime
status_msg "Internal boot image tool"
[[ -n "$RESTORE_BACKUP" ]] || status_msg "Using zip file: $ZIP_FILE"

VERSION_CHECK_LIB="${VERSION_CHECK_LIB:-/boot/install/version_check.sh}"
if [[ -z "$RESTORE_BACKUP" && -f "$VERSION_CHECK_LIB" ]]; then
    # shellcheck disable=SC1090
    . "$VERSION_CHECK_LIB"
    zip_warning="$(zip_update_warning "$ZIP_FILE" 2>/dev/null || true)"
    if [[ -n "$zip_warning" ]]; then
        ui_msg "ZIP Update Available" "$zip_warning" || true
    fi
fi
if (( SIZE == 0 )); then
    status_msg "Boot pool target size: dedicated"
else
    status_msg "Boot pool target size: ${SIZE} MiB"
fi

ONBOARDING_BOOT_DISK="$(detect_onboarding_boot_disk || true)"

# -------------------------------
# Safety checks
# -------------------------------
while ! prompt_boot_device_count; do :; done

if [[ -n "$TARGET_DISK_ARG_1" ]]; then
    if [[ -b "$(disk_path_from_name "$TARGET_DISK_ARG_1")" ]]; then
        TARGET_DISK="$TARGET_DISK_ARG_1"
    else
        log_msg "WARNING: provided first disk '$TARGET_DISK_ARG_1' is not present; prompting for selection."
        TARGET_DISK_ARG_1=""
    fi
fi

if [[ -z "${TARGET_DISK:-}" ]]; then
    while true; do
        TARGET_DISK="$(select_target_disk "Target Disk" "Select first target disk")" || {
            log_msg "Aborted."
            exit 1
        }
        TARGET_DISK="$(normalize_disk_name "$TARGET_DISK")"
        [[ -n "$TARGET_DISK" ]] || continue
        if [[ -b "$(disk_path_from_name "$TARGET_DISK")" ]]; then
            break
        fi
        if [[ "$ui_backend" != "text" ]]; then
            ui_msg "Invalid Selection" "Selected disk '/dev/$TARGET_DISK' does not exist. Choose again."
        else
            echo "Selected disk '/dev/$TARGET_DISK' does not exist. Choose again." >&2
        fi
    done
else
    TARGET_DISK="$(normalize_disk_name "$TARGET_DISK")"
fi

if (( BOOT_DEVICE_COUNT == 2 )); then
    if [[ -n "$TARGET_DISK_ARG_2" ]]; then
        if [[ -b "$(disk_path_from_name "$TARGET_DISK_ARG_2")" ]]; then
            TARGET_DISK_2="$TARGET_DISK_ARG_2"
        else
            log_msg "WARNING: provided second disk '$TARGET_DISK_ARG_2' is not present; prompting for selection."
            TARGET_DISK_ARG_2=""
        fi
    fi

    if [[ -z "${TARGET_DISK_2:-}" ]]; then
        while true; do
            TARGET_DISK_2="$(select_target_disk "Second Target Disk" "Select second target disk (first selected: /dev/$TARGET_DISK)" "$TARGET_DISK")" || {
                log_msg "Aborted."
                exit 1
            }
            TARGET_DISK_2="$(normalize_disk_name "$TARGET_DISK_2")"
            [[ -n "$TARGET_DISK_2" ]] || continue
            if [[ "$TARGET_DISK_2" == "$TARGET_DISK" ]]; then
                if [[ "$ui_backend" != "text" ]]; then
                    ui_msg "Invalid Selection" "First and second target disks must be different."
                else
                    echo "First and second target disks must be different." >&2
                fi
                continue
            fi
            if [[ -b "$(disk_path_from_name "$TARGET_DISK_2")" ]]; then
                break
            fi
            if [[ "$ui_backend" != "text" ]]; then
                ui_msg "Invalid Selection" "Selected disk '/dev/$TARGET_DISK_2' does not exist. Choose again."
            else
                echo "Selected disk '/dev/$TARGET_DISK_2' does not exist. Choose again." >&2
            fi
        done
    else
        TARGET_DISK_2="$(normalize_disk_name "$TARGET_DISK_2")"
    fi
fi

TARGET_DISK="$(normalize_disk_name "$TARGET_DISK")"
TARGET_DISK_2="$(normalize_disk_name "$TARGET_DISK_2")"

TARGET="/dev/$TARGET_DISK"
TARGET_PART3="${TARGET}3"
if [[ "$TARGET_DISK" =~ [0-9]$ ]]; then
    TARGET_PART3="${TARGET}p3"
fi

if [[ ! -b "$TARGET" ]]; then
    error_msg "ERROR: $TARGET does not exist."
    exit 1
fi

if (( BOOT_DEVICE_COUNT == 2 )); then
    TARGET_2="/dev/$TARGET_DISK_2"
    TARGET_2_PART3="${TARGET_2}3"
    if [[ "$TARGET_DISK_2" =~ [0-9]$ ]]; then
        TARGET_2_PART3="${TARGET_2}p3"
    fi

    if [[ "$TARGET_DISK_2" == "$TARGET_DISK" ]]; then
        error_msg "ERROR: first and second target disk must be different."
        exit 1
    fi
    if [[ ! -b "$TARGET_2" ]]; then
        error_msg "ERROR: $TARGET_2 does not exist."
        exit 1
    fi
fi

TARGET_SIZE_BYTES="$(blockdev --getsize64 "$TARGET" 2>/dev/null || echo 0)"
if [[ "$TARGET_SIZE_BYTES" =~ ^[0-9]+$ ]] && (( TARGET_SIZE_BYTES > 0 )); then
    TARGET_SIZE_MIB=$(( TARGET_SIZE_BYTES / 1024 / 1024 ))
    TARGET_DEDICATED_MIB=$(( TARGET_SIZE_MIB - MIN_DATA_PART_MIB ))
    (( TARGET_DEDICATED_MIB < 1 )) && TARGET_DEDICATED_MIB=1
    TARGET_AVAILABLE_MIB=$(( TARGET_SIZE_MIB * 48 / 100 ))
    (( TARGET_AVAILABLE_MIB < 1024 )) && TARGET_AVAILABLE_MIB=1024

    if (( SIZE == 0 )); then
        SIZE="$TARGET_DEDICATED_MIB"
        status_msg "Boot pool target size (dedicated): ${SIZE} MiB"
    fi

    # Keep dedicated mode non-interactive here: when SIZE=0 was explicitly
    # requested, use computed dedicated size without showing the small-disk prompt.
    # For explicit non-dedicated sizes, keep the existing safeguard prompt.
    if (( REQUESTED_DEDICATED_SIZE == 0 )) && { (( TARGET_SIZE_MIB <= DEFAULT_BOOT_SIZE_MIB )) || (( SIZE != 0 && SIZE >= TARGET_AVAILABLE_MIB )); }; then
        if ! prompt_size_for_small_disk "$TARGET_SIZE_MIB"; then
            log_msg "Aborted while selecting boot pool size."
            exit 1
        fi
    fi
fi

prompt_boot_pool_name
status_msg "Boot pool name: ${BOOT_POOL_NAME}"

if [[ -n "$ONBOARDING_BOOT_DISK" && "$TARGET" == "$ONBOARDING_BOOT_DISK" ]]; then
    error_msg "ERROR: $TARGET is the installer boot device."
    log_msg "Select a different target disk."
    exit 1
fi
if (( BOOT_DEVICE_COUNT == 2 )) && [[ -n "$ONBOARDING_BOOT_DISK" && "$TARGET_2" == "$ONBOARDING_BOOT_DISK" ]]; then
    error_msg "ERROR: $TARGET_2 is the installer boot device."
    log_msg "Select a different target disk."
    exit 1
fi

# Prevent overwriting active root disk
ROOT_SRC=$(findmnt -n -o SOURCE / || true)
if [[ "$ROOT_SRC" == *"$TARGET_DISK"* ]]; then
    error_msg "ERROR: You are running from $TARGET."
    log_msg "Refusing to overwrite active system disk."
    exit 1
fi
if (( BOOT_DEVICE_COUNT == 2 )) && [[ "$ROOT_SRC" == *"$TARGET_DISK_2"* ]]; then
    error_msg "ERROR: You are running from $TARGET_2."
    log_msg "Refusing to overwrite active system disk."
    exit 1
fi

if [[ "$ui_backend" != "text" ]]; then
    if (( BOOT_DEVICE_COUNT == 2 )); then
        confirm_text="ALL DATA on $TARGET and $TARGET_2 will be destroyed. Continue?"
    else
        confirm_text="ALL DATA on $TARGET will be destroyed. Continue?"
    fi
    if ! confirm "$confirm_text" "n"; then
        log_msg "Aborted."
        exit 1
    fi
else
    if (( BOOT_DEVICE_COUNT == 2 )); then
        CONFIRM="$(ui_prompt "Destructive Action" "ALL DATA on $TARGET and $TARGET_2 will be destroyed. Type YES to continue")"
    else
        CONFIRM="$(ui_prompt "Destructive Action" "ALL DATA on $TARGET will be destroyed. Type YES to continue")"
    fi
    [[ "$CONFIRM" != "YES" ]] && { echo "Aborted."; exit 1; }
fi

step_update "Preparing partition layout"

# -------------------------------
# Wipe disk
# -------------------------------

step_update "Wiping existing partition table"
run_operation wipefs -a "$TARGET"
run_operation parted -s "$TARGET" mklabel gpt
if (( BOOT_DEVICE_COUNT == 2 )); then
    run_operation wipefs -a "$TARGET_2"
    run_operation parted -s "$TARGET_2" mklabel gpt
fi

# -------------------------------
# Recreate partitions
# -------------------------------

step_update "Creating bootable target partitions"
run_operation mkdir -p "/boot-transfer"
DISK_ID="$(resolve_disk_id "$TARGET" || true)"
if [[ -z "$DISK_ID" ]]; then
    DISK_ID="$TARGET_DISK"
    log_msg "WARNING: could not resolve stable disk ID for $TARGET; using '$DISK_ID'."
fi
log_msg "Using DISK_ID: $DISK_ID"
if (( BOOT_DEVICE_COUNT == 2 )); then
    DISK_ID_2="$(resolve_disk_id "$TARGET_2" || true)"
    if [[ -z "$DISK_ID_2" ]]; then
        DISK_ID_2="$TARGET_DISK_2"
        log_msg "WARNING: could not resolve stable disk ID for $TARGET_2; using '$DISK_ID_2'."
    fi
    log_msg "Using DISK_ID.1: $DISK_ID_2"
fi
if (( BOOT_DEVICE_COUNT == 2 )); then
    run_operation /usr/local/ungrub/mkbootable add "$TARGET_DISK" "$SIZE"
    run_operation /usr/local/ungrub/mkbootable add "$TARGET_DISK_2" "$SIZE"
else
    run_operation /usr/local/ungrub/mkbootable add "$TARGET_DISK" "$SIZE"
fi


# -------------------------------
# Cleanup
# -------------------------------

step_update "Verifying ZFS label"
if command -v zdb >/dev/null; then
    run_operation zdb -l "$TARGET_PART3" || {
        log_msg "WARNING: ZFS label check failed."
        exit 1
    }
    if (( BOOT_DEVICE_COUNT == 2 )); then
        run_operation zdb -l "$TARGET_2_PART3" || {
            log_msg "WARNING: ZFS label check failed for second disk."
            exit 1
        }
    fi
fi

step_update "Partitioning complete; collecting disk summary"
run_operation lsblk "$TARGET"
if (( BOOT_DEVICE_COUNT == 2 )); then
    run_operation lsblk "$TARGET_2"
fi

if [[ -n "$RESTORE_BACKUP" ]]; then
    step_update "Extracting boot backup to boot-transfer"
else
    step_update "Extracting ZIP payload to boot-transfer"
fi
if [[ ! -d /boot-transfer ]]; then
    run_operation mkdir /boot-transfer
fi

if [[ -n "$RESTORE_BACKUP" ]]; then
    generated_grub_cfg="/boot-transfer/grub/grub.cfg"
    if [[ ! -f "$generated_grub_cfg" ]]; then
        error_msg "ERROR: mkbootable did not create $generated_grub_cfg"
        exit 1
    fi
    generated_unraid_uuid="$(awk 'match($0, /unraiduuid=[^[:space:]]+/) { print substr($0, RSTART + 11, RLENGTH - 11); exit }' "$generated_grub_cfg")"
    if [[ ! "$generated_unraid_uuid" =~ ^[0-9]+$ ]]; then
        error_msg "ERROR: unable to determine the new boot pool Unraid UUID"
        exit 1
    fi
    log_msg "Restoring bootloader configuration and updating its Unraid UUID for the new boot pool."
    run_operation unzip -o "$ZIP_FILE" -d /boot-transfer || exit 1
    if [[ ! -f "$generated_grub_cfg" ]]; then
        error_msg "ERROR: restore backup did not contain $generated_grub_cfg"
        exit 1
    fi
    run_operation sed -i -E "s/unraiduuid=[^[:space:]]+/unraiduuid=${generated_unraid_uuid}/g" "$generated_grub_cfg" || exit 1
    if ! grep -q "unraiduuid=${generated_unraid_uuid}" "$generated_grub_cfg"; then
        error_msg "ERROR: unable to update the restored bootloader Unraid UUID"
        exit 1
    fi
else
    # -o avoids interactive overwrite prompts when rerunning on an existing /boot-transfer.
    run_operation unzip -o "$ZIP_FILE" -d /boot-transfer \
      -x 'EFI*' 'FOUND*' 'FSCK*' 'System*' \
         'grub' 'grub/*' 'ldlinux*' 'make_bootable*' 'syslinux' 'syslinux/*' || exit 1
fi

step_update "Validating SHA256 checksums"
run_operation sync -f /boot
echo 3 > /proc/sys/vm/drop_caches
sha_list_file="$(mktemp)"
find /boot-transfer -type f -name '*.sha256' -print0 > "$sha_list_file"
while IFS= read -r -d '' sha; do
    file=${sha%.sha256}
    log_msg "checking sha256 on ${file}"
    if [[ ! -f "${file}" ]]; then
        log_msg "*** missing file for sha256 ${file}"
        badsha256="yes"
        continue
    fi
    sha256expect=$(cat "${sha}")
    sha256actual=$(/usr/bin/sha256sum "${file}")
    if [[ "${sha256actual:0:64}" != "${sha256expect:0:64}" ]]; then
        log_msg "*** bad sha256 on ${file}"
        badsha256="yes"
    fi
done < "$sha_list_file"

rm -f "$sha_list_file"
if [[ -v badsha256 ]]; then
    error_msg "***"
    log_msg "*** The upgrade failed, but no changes were made to your configuration."
    log_msg "*** Your USB Flash is likely failing."
    log_msg "***"
    exit 1
fi

run_operation /bin/sync

step_update "Writing boot configuration"
log_msg "Write ${BOOT_POOL_NAME}.cfg disk ID $DISK_ID to flash/boot/config/pools/${BOOT_POOL_NAME}.cfg"
if [[ ! -d /boot-transfer/config/pools ]]; then
    mkdir -p /boot-transfer/config/pools
fi  

cat > "/boot-transfer/config/pools/${BOOT_POOL_NAME}.cfg" <<EOF
diskFsType="auto"
diskUUID=""
diskAutotrim=""
diskCompression=""
diskWarning=""
diskCritical=""
diskExpansion=""
diskShareEnabled="yes"
diskShareFloor="0"
diskBootSize="$SIZE"
diskComment=""
diskExport="-"
diskFruit="no"
diskSecurity="public"
diskReadList=""
diskWriteList=""
diskVolsizelimit=""
diskCaseSensitive="auto"
diskExportNFS="-"
diskExportNFSFsid="0"
diskSecurityNFS="public"
diskHostListNFS=""
diskSpindownDelay="-1"
diskSpinupGroup=""
diskFsProfile=""
diskFsWidth="1"
diskFsGroups="1"
diskId="$DISK_ID"
diskIdSlot="-"
diskSize="0"
EOF

if (( BOOT_DEVICE_COUNT == 2 )); then
cat >> "/boot-transfer/config/pools/${BOOT_POOL_NAME}.cfg" <<EOF
diskId.1="$DISK_ID_2"
diskIdSlot.1="-"
diskSize.1="0"
EOF
fi

log_msg "pool cfg written: /boot-transfer/config/pools/${BOOT_POOL_NAME}.cfg (diskId=$DISK_ID)"

step_update "Exporting flash pool"
run_operation zpool export flash

status_msg "Internal boot image creation complete"
log_msg "Operation log: $RUN_LOG_FILE"

if [[ -n "$RESTORE_BACKUP" ]]; then
    if [[ "$ui_backend" != "text" ]]; then
        ui_msg "Restore Complete" "Boot backup restored successfully. Showing the operation log."
    fi
    ui_view_log "Boot Backup Restore Log" "$RUN_LOG_FILE"
elif [[ "$ui_backend" != "text" ]]; then
    ui_msg "Internal Boot Complete" "Internal boot image creation complete."
fi

if [[ -z "$RESTORE_BACKUP" ]] && confirm "View full operation log now?" "n"; then
    ui_view_log "Internal Boot Full Log" "$RUN_LOG_FILE"
fi
