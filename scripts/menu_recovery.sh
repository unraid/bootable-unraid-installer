#!/bin/bash
set -euo pipefail

ui_backend=""
RECOVERY_LOG=()
SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_MENU_LIB=""

for candidate in "${MENU_GUI_COMMON_LIB:-}" "/boot/install/menu_gui_common.sh" "$SCRIPT_SELF_DIR/menu_gui_common.sh"; do
    [[ -n "$candidate" && -f "$candidate" ]] || continue
    COMMON_MENU_LIB="$candidate"
    break
done

if [[ -z "$COMMON_MENU_LIB" ]]; then
    echo "Missing common menu library (menu_gui_common.sh)." >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$COMMON_MENU_LIB"

recovery_status() {
    local message="$1"

    RECOVERY_LOG+=("$(date '+%H:%M:%S')  $message")

    case "$ui_backend" in
        whiptail)
            whiptail --title "Password Reset" --infobox "$message" 8 80
            ;;
        dialog)
            dialog --title "Password Reset" --infobox "$message" 8 80
            ;;
        *)
            printf '[Password Reset] %s\n' "$message"
            ;;
    esac
}

recovery_log_text() {
    printf '%s\n' "${RECOVERY_LOG[@]}"
}

reset_unraid_password() {
    local pool_name="${RECOVERY_BOOT_POOL:-flash}"
    local mount_root=""
    local config_dir=""
    local dataset_lines=""
    local dataset mountpoint root_mountpoint resolved_mount_root resolved_config_dir

    if ! command -v zpool >/dev/null 2>&1 || ! command -v zfs >/dev/null 2>&1; then
        ui_msg "Password Reset" "ZFS tools are not available in this image."
        return 1
    fi

    if zpool list -H -o name "$pool_name" >/dev/null 2>&1; then
        ui_msg "Password Reset" "The '$pool_name' boot pool is already imported. Refusing to modify an active pool."
        return 1
    fi

    if ! ui_confirm "Reset Password" "This removes config/passwd and config/shadow from the '$pool_name' boot pool. The next Unraid boot will have no web password. Continue?"; then
        return 0
    fi

    mount_root="$(mktemp -d /mnt/unraid-recovery.XXXXXX)"
    recovery_status "Importing ZFS boot pool '$pool_name'..."
    if ! zpool import -N -R "$mount_root" "$pool_name"; then
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "Unable to import ZFS boot pool '$pool_name'. Ensure the target boot device is connected and not in use."
        return 1
    fi

    recovery_status "Reading datasets from '$pool_name'..."
    if ! dataset_lines="$(zfs list -H -o name,mountpoint -r "$pool_name")"; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "Unable to list datasets in the '$pool_name' boot pool."
        return 1
    fi

    while IFS=$'\t' read -r dataset mountpoint; do
        [[ -n "$dataset" ]] || continue
        [[ "$mountpoint" == "legacy" || "$mountpoint" == "none" || "$mountpoint" == "-" ]] && continue
        recovery_status "Mounting dataset '$dataset'..."
        if ! zfs mount "$dataset"; then
            zpool export "$pool_name" >/dev/null 2>&1 || true
            rmdir "$mount_root" 2>/dev/null || true
            ui_msg "Password Reset" "The '$pool_name' boot dataset could not be mounted."
            return 1
        fi
    done <<< "$dataset_lines"

    if [[ -z "$dataset_lines" ]]; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "No datasets were found in the '$pool_name' boot pool."
        return 1
    fi

    recovery_status "Locating the Unraid config directory..."
    root_mountpoint="$(zfs get -H -o value mountpoint "$pool_name" 2>/dev/null || true)"
    if [[ "$root_mountpoint" != /* ]]; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "The '$pool_name' boot dataset does not have a usable mount point."
        return 1
    fi
    config_dir="$mount_root${root_mountpoint%/}/config"
    if [[ -L "$config_dir" ]]; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "The boot config directory is a symlink. Refusing to modify it."
        return 1
    fi
    resolved_mount_root="$(readlink -f -- "$mount_root" 2>/dev/null || true)"
    resolved_config_dir="$(readlink -f -- "$config_dir" 2>/dev/null || true)"
    if [[ -z "$resolved_mount_root" || -z "$resolved_config_dir" || "$resolved_config_dir" != "$resolved_mount_root"/* || ! -d "$resolved_config_dir" ]]; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "Expected config directory is unavailable or outside the boot pool."
        return 1
    fi
    config_dir="$resolved_config_dir"

    recovery_status "Deleting config/passwd and config/shadow..."
    if ! rm -f -- "$config_dir/passwd" "$config_dir/shadow"; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "Unable to remove the saved password files."
        return 1
    fi

    recovery_status "Verifying password files are absent..."
    if [[ -e "$config_dir/passwd" || -e "$config_dir/shadow" ]]; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "The password files are still present in the config directory."
        return 1
    fi

    recovery_status "Syncing changes to '$pool_name'..."
    if ! sync; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "Unable to sync the password reset changes."
        return 1
    fi

    recovery_status "Exporting ZFS boot pool '$pool_name'..."
    if ! zpool export "$pool_name"; then
        ui_msg "Password Reset" "Password files were removed, but the '$pool_name' pool could not be exported. Export it before rebooting."
        return 1
    fi
    rmdir "$mount_root" 2>/dev/null || true
    recovery_status "Password reset complete."
    ui_msg "Password Reset Complete" "$(recovery_log_text)

Password files were removed successfully. You can now boot Unraid and set a new password."
}

recovery_menu() {
    local choice=""

    if [[ "$ui_backend" == "text" ]]; then
        choice="$(ui_hotkey_select "Recovery" "Select a recovery action" A "Reset password" B "Back")"
    else
        choice="$(ui_menu "Recovery" "Select a recovery action" A "Reset password" B "Back")" || return 0
    fi
    choice="${choice//$'\r'/}"
    choice="${choice//[[:space:]]/}"
    choice="${choice^^}"

    case "$choice" in
        A) reset_unraid_password ;;
        *) ;;
    esac
}

detect_ui_backend
recovery_menu
