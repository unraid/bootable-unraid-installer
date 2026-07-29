#!/bin/bash
set -euo pipefail

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

reset_unraid_password() {
    local pool_name="${RECOVERY_BOOT_POOL:-flash}"
    local mount_root=""
    local dataset_list=""
    local config_dir=""
    local dataset mountpoint

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
    if ! zpool import -N -R "$mount_root" "$pool_name"; then
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "Unable to import ZFS boot pool '$pool_name'. Ensure the target boot device is connected and not in use."
        return 1
    fi

    dataset_list="$(mktemp /tmp/unraid-recovery-datasets.XXXXXX)"
    if ! zfs list -H -o name,mountpoint -r "$pool_name" > "$dataset_list"; then
        rm -f "$dataset_list"
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "Unable to list datasets in the '$pool_name' boot pool."
        return 1
    fi

    while IFS=$'\t' read -r dataset mountpoint; do
        [[ -n "$dataset" ]] || continue
        [[ "$mountpoint" == "legacy" || "$mountpoint" == "none" || "$mountpoint" == "-" ]] && continue
        if ! zfs mount "$dataset"; then
            rm -f "$dataset_list"
            zpool export "$pool_name" >/dev/null 2>&1 || true
            rmdir "$mount_root" 2>/dev/null || true
            ui_msg "Password Reset" "The '$pool_name' boot dataset could not be mounted."
            return 1
        fi
    done < "$dataset_list"
    rm -f "$dataset_list"

    config_dir="$(find -P "$mount_root" -type d -name config -print -quit 2>/dev/null || true)"
    if [[ -z "$config_dir" ]]; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "No config directory was found on the '$pool_name' boot pool."
        return 1
    fi

    if ! rm -f -- "$config_dir/passwd" "$config_dir/shadow" || ! sync; then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        rmdir "$mount_root" 2>/dev/null || true
        ui_msg "Password Reset" "Unable to remove the saved password files."
        return 1
    fi

    if ! zpool export "$pool_name"; then
        ui_msg "Password Reset" "Password files were removed, but the '$pool_name' pool could not be exported. Export it before rebooting."
        return 1
    fi
    rmdir "$mount_root" 2>/dev/null || true
    ui_msg "Password Reset" "Password files removed successfully. You can now boot Unraid and set a new password."
}

recovery_menu() {
    local choice=""

    if ! choice="$(ui_menu "Recovery" "Select a recovery action" 1 "Reset password" B "Back")"; then
        choice="$(ui_hotkey_select "Recovery" "Select a recovery action" 1 "Reset password" B "Back")"
    fi
    choice="${choice//$'\r'/}"
    choice="${choice//[[:space:]]/}"
    choice="${choice^^}"

    case "$choice" in
        1) reset_unraid_password ;;
        *) ;;
    esac
}

detect_ui_backend
recovery_menu
