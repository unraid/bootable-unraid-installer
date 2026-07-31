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
backup_file=""

select_backup() {
    local -a menu_args=()
    local file choice=1 list_file
    list_file="$(mktemp /tmp/unraid-recovery-backups.XXXXXX)"
    (
        shopt -s nullglob nocaseglob
        for file in "$backup_dir"/*.zip; do
            printf '%s\n' "${file##*/}"
        done
    ) | sort > "$list_file"
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
if ! select_backup; then
    ui_msg "Restore Boot Backup" "No backup ZIP was selected from $backup_dir."
    exit 0
fi

if [[ "$ui_backend" == "text" ]]; then
    ui_mode="text"
else
    ui_mode="gui"
fi

exec /bin/bash /boot/install/create_internal_boot.sh --ui "$ui_mode" --restore-backup "$backup_file"
