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

backup_dir="/mnt/persist/recovery-backups"
mount_dir="/boot-transfer"
backup_file=""

select_backup() {
    local -a menu_args=()
    local file choice=1 list_file
    list_file="$(mktemp /tmp/unraid-recovery-backups.XXXXXX)"
    find "$backup_dir" -maxdepth 1 -type f -iname '*.zip' -printf '%f\n' | sort > "$list_file"
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        menu_args+=("$choice" "$(basename "$file")")
        ((++choice))
    done < "$list_file"
    rm -f "$list_file"
    [[ ${#menu_args[@]} -gt 0 ]] || return 1
    if [[ "$ui_backend" == "text" ]]; then
        choice="$(ui_hotkey_select "Restore Boot Backup" "Select uploaded backup" "${menu_args[@]}")" || return 1
    else
        choice="$(ui_menu "Restore Boot Backup" "Select uploaded backup" "${menu_args[@]}")" || return 1
    fi
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    backup_file="${menu_args[$(( (choice - 1) * 2 + 1 ))]}"
    backup_file="$backup_dir/$backup_file"
}

if ! mountpoint -q /mnt/persist; then
    ui_msg "Restore Boot Backup" "Persistent storage is not mounted."
    exit 1
fi
if ! command -v unzip >/dev/null 2>&1 || [[ ! -x /usr/local/ungrub/mkbootable ]]; then
    ui_msg "Restore Boot Backup" "Required restore tools are unavailable."
    exit 1
fi
if ! select_backup; then
    ui_msg "Restore Boot Backup" "No backup ZIP was selected from $backup_dir."
    exit 0
fi

if ! unzip -Z1 "$backup_file" | grep -qx 'config/' || ! unzip -Z1 "$backup_file" | grep -qx 'bzimage'; then
    ui_msg "Restore Boot Backup" "The selected archive is not a complete Unraid boot backup. It must contain config/ and bzimage."
    exit 1
fi
if unzip -Z1 "$backup_file" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    ui_msg "Restore Boot Backup" "The selected archive contains unsafe paths."
    exit 1
fi

target="$(lsblk -dn -o NAME,TYPE | awk '$2=="disk" {print $1}' | while IFS= read -r disk; do [[ "/dev/$disk" == "${ONBOARDING_BOOT_DISK:-}" ]] || printf '%s\n' "$disk"; done | head -n1)"
target="$(ui_prompt "Restore Boot Backup" "Enter target disk name (all data will be erased), for example nvme0n1" "$target")"
target="${target#/dev/}"
[[ -b "/dev/$target" ]] || { ui_msg "Restore Boot Backup" "Invalid target disk: /dev/$target"; exit 1; }
[[ "/dev/$target" != "${ONBOARDING_BOOT_DISK:-}" ]] || { ui_msg "Restore Boot Backup" "The installer boot device cannot be restored onto itself."; exit 1; }

confirm="$(ui_prompt "Confirm Restore" "This destroys all data on /dev/$target. Type RESTORE to continue" "")"
[[ "$confirm" == "RESTORE" ]] || exit 0

ui_msg "Restore Boot Backup" "Creating the bootable base disk. This may take a moment."
wipefs -a "/dev/$target"
parted -s "/dev/$target" mklabel gpt
mkdir -p "$mount_dir"
/usr/local/ungrub/mkbootable add "$target" "${RECOVERY_BOOT_SIZE_MIB:-8192}"

ui_msg "Restore Boot Backup" "Restoring $(basename "$backup_file") to the boot dataset."
unzip -o "$backup_file" -d "$mount_dir" >/tmp/unraid-recovery-restore.log
sync
zpool export flash

ui_msg "Restore Complete" "Restored $(basename "$backup_file") to /dev/$target. The flash pool has been exported and is ready to boot."
