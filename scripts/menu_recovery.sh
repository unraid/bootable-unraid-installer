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
    local boot_dataset="${RECOVERY_BOOT_DATASET:-${pool_name}/boot}"
    local mount_root=""
    local config_dir=""
    local boot_mountpoint=""
    local resolved_mount_root=""
    local resolved_config_dir=""
    local shadow_file=""
    local shadow_tmp=""

    if ! command -v zpool >/dev/null 2>&1 || ! command -v zfs >/dev/null 2>&1; then
        ui_msg "Password Reset" "ZFS tools are not available in this image."
        return 1
    fi

    if zpool list -H -o name "$pool_name" >/dev/null 2>&1; then
        ui_msg "Password Reset" "The '$pool_name' boot pool is already imported. Refusing to modify an active pool."
        return 1
    fi

    if ! ui_confirm "Reset Password" "This clears only the root password in the '$pool_name' boot pool. Other users and SMB passwords are preserved. Continue?"; then
        return 0
    fi

    mount_root="$(mktemp -d /mnt/unraid-recovery.XXXXXX)"
    recovery_status "Importing ZFS boot pool '$pool_name'..."
    if ! zpool import -N -R "$mount_root" "$pool_name"; then
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "Unable to import ZFS boot pool '$pool_name'. Ensure the target boot device is connected and not in use."
        return 1
    fi

    if ! zfs list -H -o name "$boot_dataset" >/dev/null 2>&1; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "The expected boot dataset '$boot_dataset' was not found."
        return 1
    fi

    recovery_status "Mounting boot dataset '$boot_dataset'..."
    if ! zfs mount "$boot_dataset"; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "The '$boot_dataset' boot dataset could not be mounted."
        return 1
    fi

    boot_mountpoint="$(zfs get -H -o value mountpoint "$boot_dataset" 2>/dev/null || true)"
    if [[ -z "$boot_mountpoint" || "$boot_mountpoint" == "legacy" || "$boot_mountpoint" == "none" || "$boot_mountpoint" != /* ]]; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "The '$boot_dataset' dataset does not have a usable mount point."
        return 1
    fi

    recovery_status "Locating the Unraid config directory in '$boot_dataset'..."
    resolved_mount_root="$(readlink -f -- "$mount_root" 2>/dev/null || true)"
    if [[ -z "$resolved_mount_root" ]]; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "Unable to resolve the temporary boot-pool mount root."
        return 1
    fi

    if [[ "$boot_mountpoint" == "$mount_root" || "$boot_mountpoint" == "$mount_root"/* ]]; then
        config_dir="${boot_mountpoint%/}/config"
    else
        config_dir="$mount_root${boot_mountpoint%/}/config"
    fi
    if [[ -L "$config_dir" ]]; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "A boot config directory is a symlink. Refusing to modify it."
        return 1
    fi

    resolved_config_dir="$(readlink -f -- "$config_dir" 2>/dev/null || true)"
    if [[ -z "$resolved_config_dir" || "$resolved_config_dir" != "$resolved_mount_root"/* || ! -d "$resolved_config_dir" ]]; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "The expected config directory was not found at '$config_dir'."
        return 1
    fi
    config_dir="$resolved_config_dir"

    shadow_file="$config_dir/shadow"
    if [[ -L "$shadow_file" ]]; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "The saved shadow file is a symbolic link. Refusing to modify it."
        return 1
    fi
    if [[ -f "$shadow_file" ]]; then
        if ! grep -q '^root:' "$shadow_file"; then
            zpool export "$pool_name" >/dev/null 2>&1 || true
            rmdir "$mount_root" 2>/dev/null || true
            ui_msg "Password Reset" "The saved shadow file does not contain a root entry."
            return 1
        fi
        if ! shadow_tmp="$(mktemp "$config_dir/.shadow.XXXXXX")"; then
            zpool export "$pool_name" >/dev/null 2>&1 || true
            rmdir "$mount_root" 2>/dev/null || true
            ui_msg "Password Reset" "Unable to create a temporary password-reset file."
            return 1
        fi
        recovery_status "Clearing the root password in '$shadow_file'..."
        if ! awk -F: 'BEGIN { OFS=FS } $1 == "root" { $2="" } { print }' "$shadow_file" > "$shadow_tmp" || ! mv -f -- "$shadow_tmp" "$shadow_file"; then
            rm -f -- "$shadow_tmp"
            zpool export "$pool_name" >/dev/null 2>&1 || true
            rmdir "$mount_root" 2>/dev/null || true
            ui_msg "Password Reset" "Unable to update the saved root password."
            return 1
        fi
        shadow_tmp=""
        if ! awk -F: '$1 == "root" { found=1; if ($2 != "") bad=1 } END { exit (!found || bad) }' "$shadow_file"; then
            zpool export "$pool_name" >/dev/null 2>&1 || true
            rmdir "$mount_root" 2>/dev/null || true
            ui_msg "Password Reset" "The saved root password could not be cleared."
            return 1
        fi
    else
        recovery_status "No saved shadow file found; the root password is already unset."
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
        ui_msg "Password Reset" "The root password was reset, but the '$pool_name' pool could not be exported. Export it before rebooting."
        return 1
    fi
    rmdir "$mount_root" 2>/dev/null || true
    recovery_status "Password reset complete."
    ui_msg "Password Reset Complete" "$(recovery_log_text)

The root password was reset successfully. You can now boot Unraid and set a new password."
}

start_recovery_smb() {
    /bin/bash /boot/install/menu_recovery_smb.sh
}

start_recovery_smb_authenticated() {
    /bin/bash /boot/install/menu_recovery_smb.sh --authenticated
}

start_recovery_restore() {
    /bin/bash /boot/install/menu_recovery_restore.sh
}

start_recovery_restore_existing() {
    /bin/bash /boot/install/menu_recovery_restore_existing.sh
}

recovery_menu() {
    local choice=""

    while true; do
        if [[ "$ui_backend" == "text" ]]; then
            choice="$(ui_hotkey_select "Recovery" "Select a recovery action" A "Reset password" B "Start Guest SMB Backup Share" C "Start Authenticated SMB Backup Share" D "Create Internal Boot from Backup" E "Restore Existing Internal Boot" F "Back")"
        else
            choice="$(ui_menu "Recovery" "Select a recovery action" A "Reset password" B "Start Guest SMB Backup Share" C "Start Authenticated SMB Backup Share" D "Create Internal Boot from Backup" E "Restore Existing Internal Boot" F "Back")" || return 0
        fi
        choice="${choice//$'\r'/}"
        choice="${choice//[[:space:]]/}"
        choice="${choice^^}"

        case "$choice" in
            A) reset_unraid_password ;;
            B) start_recovery_smb ;;
            C) start_recovery_smb_authenticated ;;
            D) start_recovery_restore ;;
            E) start_recovery_restore_existing ;;
            *) return 0 ;;
        esac
    done
}

detect_ui_backend
recovery_menu
