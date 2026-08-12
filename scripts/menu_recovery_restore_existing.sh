#!/bin/bash
set -euo pipefail

ui_backend=""
SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_MENU_LIB=""
for candidate in "${MENU_GUI_COMMON_LIB:-}" "/boot/install/menu_gui_common.sh" "$SCRIPT_SELF_DIR/menu_gui_common.sh"; do
    [[ -n "$candidate" && -f "$candidate" ]] || continue
    COMMON_MENU_LIB="$candidate"
    break
done
[[ -n "$COMMON_MENU_LIB" ]] || { echo "Missing common menu library." >&2; exit 1; }
# shellcheck disable=SC1090
. "$COMMON_MENU_LIB"

detect_ui_backend

backup_dir="/mnt/persist/recovery-backups"
pool_name="${RECOVERY_BOOT_POOL:-flash}"
boot_dataset="${RECOVERY_BOOT_DATASET:-${pool_name}/boot}"
backup_file=""
mount_root=""

cleanup() {
    [[ -n "$mount_root" ]] || return
    zpool export "$pool_name" >/dev/null 2>&1 || true
    rmdir "$mount_root" 2>/dev/null || true
}
trap cleanup EXIT

select_backup() {
    local -a menu_args=()
    local file choice=1 list_file backup_count

    list_file="$(mktemp /tmp/unraid-recovery-backups.XXXXXX)"
    (
        shopt -s nullglob nocaseglob
        for file in "$backup_dir"/*.zip; do
            printf '%s\n' "${file##*/}"
        done
    ) | sort > "$list_file"
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        menu_args+=("$choice" "$file")
        ((++choice))
    done < "$list_file"
    rm -f "$list_file"
    [[ ${#menu_args[@]} -gt 0 ]] || return 1
    backup_count=$(( ${#menu_args[@]} / 2 ))

    if [[ "$ui_backend" == "text" ]]; then
        choice="$(ui_hotkey_select "Restore Existing Internal Boot" "Select uploaded backup" "${menu_args[@]}")" || return 1
    else
        choice="$(ui_menu "Restore Existing Internal Boot" "Select uploaded backup" "${menu_args[@]}")" || return 1
    fi
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    (( choice >= 1 && choice <= backup_count )) || return 1
    backup_file="$backup_dir/${menu_args[$(( (choice - 1) * 2 + 1 ))]}"
}

validate_backup() {
    unzip -tqq "$backup_file" >/dev/null || return 1
    unzip -Z1 "$backup_file" | grep -qx 'config/' || return 1
    unzip -Z1 "$backup_file" | grep -qx 'bzimage' || return 1
    ! unzip -Z1 "$backup_file" | grep -Eq '(^/|(^|/)\.\.(/|$))' || return 1
    ! unzip -Z -l "$backup_file" | awk 'NR > 3 && $1 ~ /^l/ { found = 1 } END { exit !found }'
}

if ! mountpoint -q /mnt/persist; then
    ui_msg "Restore Existing Internal Boot" "Persistent storage is not mounted."
    exit 1
fi
if ! command -v zpool >/dev/null 2>&1 || ! command -v zfs >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    ui_msg "Restore Existing Internal Boot" "Required ZFS or ZIP tools are not available in this installer image."
    exit 1
fi
if zpool list -H -o name "$pool_name" >/dev/null 2>&1; then
    ui_msg "Restore Existing Internal Boot" "The '$pool_name' boot pool is already imported. Refusing to modify an active pool."
    exit 1
fi
if ! select_backup; then
    ui_msg "Restore Existing Internal Boot" "No backup ZIP was selected from $backup_dir."
    exit 0
fi
if ! validate_backup; then
    ui_msg "Restore Existing Internal Boot" "The selected ZIP is invalid, unsafe, or does not contain config/ and bzimage."
    exit 1
fi
if ! ui_confirm "Restore Existing Internal Boot" "This replaces all files in the existing '$boot_dataset' boot filesystem with '$backup_file'.\n\nThe disk partition table and user-data partition p4 are not modified. Continue?"; then
    exit 0
fi

mount_root="$(mktemp -d /mnt/unraid-restore.XXXXXX)"
if ! zpool import -N -R "$mount_root" "$pool_name"; then
    ui_msg "Restore Existing Internal Boot" "Unable to import ZFS boot pool '$pool_name'. Ensure the target boot device is connected and not in use."
    exit 1
fi
if ! zfs list -H -o name "$boot_dataset" >/dev/null 2>&1 || ! zfs mount "$boot_dataset"; then
    ui_msg "Restore Existing Internal Boot" "Unable to mount the '$boot_dataset' boot filesystem."
    exit 1
fi
boot_mountpoint="$(zfs get -H -o value mountpoint "$boot_dataset" 2>/dev/null || true)"
if [[ -z "$boot_mountpoint" || "$boot_mountpoint" != "$mount_root"/* || ! -d "$boot_mountpoint" ]]; then
    ui_msg "Restore Existing Internal Boot" "The '$boot_dataset' dataset has an unsafe mount point."
    exit 1
fi

if ! find "$boot_mountpoint" -mindepth 1 -xdev -delete; then
    ui_msg "Restore Existing Internal Boot" "Unable to clear the existing boot filesystem."
    exit 1
fi
if ! unzip -o "$backup_file" -d "$boot_mountpoint" >/dev/null; then
    ui_msg "Restore Existing Internal Boot" "Unable to extract the backup ZIP to the boot filesystem."
    exit 1
fi
sync
zpool export "$pool_name"
rmdir "$mount_root" 2>/dev/null || true
mount_root=""
ui_msg "Restore Complete" "Backup restored to the existing internal boot filesystem. The partition table and p4 user-data partition were not modified."
