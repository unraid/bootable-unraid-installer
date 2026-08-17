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
selected_backup_file=""
staged_backup=""
mount_root=""
pool_imported=0
snapshot_name=""
snapshot_created=0
pool_guid=""
checksum_error=""
if [[ -n "${RUN_LOG_FILE:-}" ]]; then
    run_log_file="$RUN_LOG_FILE"
elif [[ -d /mnt/persist/logs && -w /mnt/persist/logs ]]; then
    run_log_file="$(mktemp /mnt/persist/logs/restore-existing.XXXXXX.log)"
else
    run_log_file="$(mktemp /run/unraid-restore-existing.XXXXXX.log 2>/dev/null || mktemp /tmp/unraid-restore-existing.XXXXXX.log)"
fi

log_msg() {
    printf '%s\n' "$*" | tee -a "$run_log_file" >&2
}

status_msg() {
    local message="$1"
    printf '%s\n' "$message" >>"$run_log_file"
    case "$ui_backend" in
        whiptail) whiptail --title "Restore Existing Internal Boot" --infobox "$message" 8 80 ;;
        dialog) dialog --title "Restore Existing Internal Boot" --infobox "$message" 8 80 ;;
        *) log_msg "$message" ;;
    esac
}

view_log() {
    local title="$1"
    local file="$2"
    case "$ui_backend" in
        whiptail) whiptail --title "$title" --scrolltext --textbox "$file" 22 100 ;;
        dialog) dialog --title "$title" --textbox "$file" 22 100 ;;
        *)
            printf '\n[%s] (use a pager or arrow keys to scroll)\n\n' "$title"
            cat "$file"
            printf '\n'
            read -r -p "Press Enter to continue..." _
            ;;
    esac
}

show_failure_log() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        touch "$run_log_file" 2>/dev/null || true
        ui_msg "Restore Failed" "The restore failed.\n\nOperation log:\n$run_log_file"
        if ui_confirm "Restore Failed" "Review the operation log now?" "y"; then
            view_log "Restore Operation Log (Failed)" "$run_log_file"
        fi
    fi
    return "$exit_code"
}
trap show_failure_log EXIT
log_msg "Restore Existing Internal Boot started. Log: $run_log_file"

archive_contains_symlink() {
    unzip -Z -v "$1" 2>/dev/null | awk '
        /Unix file attributes \(/ {
            attr=$0
            sub(/^.*\(/, "", attr)
            sub(/ octal\).*$/, "", attr)
            if (attr ~ /^0?12[0-7][0-7][0-7][0-7]$/) {
                found=1
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

cleanup() {
    if (( snapshot_created && pool_imported )); then
        zfs unmount "$boot_dataset" >/dev/null 2>&1 || true
        if zfs rollback "$snapshot_name" >/dev/null 2>&1; then
            zfs destroy "$snapshot_name" >/dev/null 2>&1 || true
            snapshot_created=0
        fi
    fi
    if (( pool_imported )); then
        zpool export "$pool_name" >/dev/null 2>&1 || true
        pool_imported=0
    fi
    [[ -n "$staged_backup" ]] && rm -f -- "$staged_backup"
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
    ! archive_contains_symlink "$backup_file"
}

extract_unraid_uuid() {
    awk '
        match($0, /unraiduuid=[^[:space:]]+/) {
            value=substr($0, RSTART + 11, RLENGTH - 11)
            if (value ~ /^[0-9]+$/) {
                print value
                exit
            }
        }
    '
}

validate_tree_checksums() {
    local root="$1"
    local checksum_file relative_file payload_file expected actual checksum_count=0
    local -a checksum_files=()

    shopt -s nullglob globstar
    checksum_files=("$root"/**/*.sha256 "$root"/**/*.SHA256)

    for checksum_file in "${checksum_files[@]}"; do
        checksum_count=$((checksum_count + 1))
        relative_file="${checksum_file#"$root"/}"
        payload_file="$root/${relative_file%.sha256}"
        if [[ ! -f "$payload_file" ]]; then
            checksum_error="Checksum payload missing: ${relative_file%.sha256}"
            log_msg "Checksum payload missing: ${relative_file%.sha256}"
            return 1
        fi
        expected="$(awk 'NF { print $1; exit }' "$checksum_file")"
        if [[ ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
            checksum_error="Invalid SHA-256 value in $relative_file"
            log_msg "Invalid SHA-256 value in $relative_file"
            return 1
        fi
        actual="$(sha256sum "$payload_file" | awk '{print $1}')"
        [[ "${expected,,}" == "${actual,,}" ]] || {
            checksum_error="Checksum mismatch: ${relative_file%.sha256}\nExpected: $expected\nActual:   $actual"
            log_msg "Checksum mismatch: ${relative_file%.sha256}"
            log_msg "Expected: $expected"
            log_msg "Actual:   $actual"
            return 1
        }
    done
    if (( checksum_count == 0 )); then
        checksum_error="No SHA-256 checksum files found under $root"
        log_msg "$checksum_error"
        return 1
    fi
    log_msg "Validated $checksum_count SHA-256 checksum file(s) under $root."
}

if ! mountpoint -q /mnt/persist; then
    ui_msg "Restore Existing Internal Boot" "Persistent storage is not mounted."
    exit 1
fi
if ! command -v zpool >/dev/null 2>&1 || ! command -v zfs >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
    ui_msg "Restore Existing Internal Boot" "Required ZFS, ZIP, or SHA-256 tools are not available in this installer image."
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

selected_backup_file="$backup_file"
status_msg "Preparing the selected backup ZIP..."
staged_backup="$(mktemp /run/unraid-restore-backup.XXXXXX)"
rm -f -- "$staged_backup"
if ! cp -P -- "$selected_backup_file" "$staged_backup" || [[ ! -f "$staged_backup" || -L "$staged_backup" ]]; then
    rm -f -- "$staged_backup"
    staged_backup=""
    ui_msg "Restore Existing Internal Boot" "Unable to safely stage the selected backup ZIP."
    exit 1
fi
chmod 0600 "$staged_backup"
backup_file="$staged_backup"
status_msg "Validating the selected backup ZIP..."
if ! validate_backup; then
    ui_msg "Restore Existing Internal Boot" "The selected ZIP is invalid, unsafe, or does not contain config/ and bzimage."
    exit 1
fi
if ! ui_confirm "Restore Existing Internal Boot" "This replaces all files in the existing '$boot_dataset' boot filesystem with '$selected_backup_file'.\n\nThe disk partition table and user-data partition p4 are not modified. Continue?"; then
    exit 0
fi

status_msg "Importing the existing ZFS boot pool..."
mount_root="$(mktemp -d /mnt/unraid-restore.XXXXXX)"
if ! zpool import -N -R "$mount_root" "$pool_name"; then
    ui_msg "Restore Existing Internal Boot" "Unable to import ZFS boot pool '$pool_name'. Ensure the target boot device is connected and not in use."
    exit 1
fi
pool_imported=1
if ! zfs list -H -o name "$boot_dataset" >/dev/null 2>&1 || ! zfs mount "$boot_dataset"; then
    ui_msg "Restore Existing Internal Boot" "Unable to mount the '$boot_dataset' boot filesystem."
    exit 1
fi
boot_mountpoint="$(zfs get -H -o value mountpoint "$boot_dataset" 2>/dev/null || true)"
if [[ -z "$boot_mountpoint" || "$boot_mountpoint" != "$mount_root"/* || ! -d "$boot_mountpoint" ]]; then
    ui_msg "Restore Existing Internal Boot" "The '$boot_dataset' dataset has an unsafe mount point."
    exit 1
fi

pool_guid="$(zpool get -H -o value guid "$pool_name" 2>/dev/null || true)"
if [[ ! "$pool_guid" =~ ^[0-9]+$ ]]; then
    ui_msg "Restore Existing Internal Boot" "Unable to determine the GUID of the target ZFS pool. The restore was not applied."
    exit 1
fi
backup_unraid_uuid="$(unzip -p "$backup_file" grub/grub.cfg 2>/dev/null | extract_unraid_uuid || true)"
if [[ -z "$backup_unraid_uuid" ]]; then
    ui_msg "Restore Existing Internal Boot" "The backup has no valid grub/grub.cfg unraiduuid. The restore was not applied."
    exit 1
fi
log_msg "Backup unraiduuid is $backup_unraid_uuid; it will be updated to target ZFS pool GUID $pool_guid."

status_msg "Creating a rollback snapshot..."
snapshot_name="${boot_dataset}@unraid-restore-${BASHPID}"
if ! zfs snapshot "$snapshot_name"; then
    ui_msg "Restore Existing Internal Boot" "Unable to create a rollback snapshot for '$boot_dataset'."
    exit 1
fi
snapshot_created=1

status_msg "Replacing the ZFS boot filesystem contents..."
if ! find "$boot_mountpoint" -mindepth 1 -xdev -delete; then
    ui_msg "Restore Existing Internal Boot" "Unable to clear the existing boot filesystem."
    exit 1
fi
status_msg "Extracting the boot backup..."
if ! unzip -o "$backup_file" -d "$boot_mountpoint" >>"$run_log_file" 2>&1; then
    ui_msg "Restore Existing Internal Boot" "Unable to extract the backup ZIP to the boot filesystem."
    exit 1
fi
restored_grub_cfg="$boot_mountpoint/grub/grub.cfg"
if [[ ! -f "$restored_grub_cfg" ]]; then
    ui_msg "Restore Existing Internal Boot" "The backup did not restore grub/grub.cfg."
    exit 1
fi
status_msg "Updating GRUB for the current ZFS pool GUID..."
if ! sed -i -E "s/unraiduuid=[^[:space:]]+/unraiduuid=${pool_guid}/g" "$restored_grub_cfg"; then
    ui_msg "Restore Existing Internal Boot" "Unable to update grub/grub.cfg with the target ZFS pool GUID."
    exit 1
fi
if ! grep -q "unraiduuid=${pool_guid}" "$restored_grub_cfg"; then
    ui_msg "Restore Existing Internal Boot" "The restored GRUB configuration does not contain the target ZFS pool GUID."
    exit 1
fi
if [[ -f "${restored_grub_cfg}.sha256" ]]; then
    sha256sum "$restored_grub_cfg" | awk '{print $1}' > "${restored_grub_cfg}.sha256"
fi
status_msg "Validating restored file checksums..."
if ! validate_tree_checksums "$boot_mountpoint"; then
    ui_msg "Restore Existing Internal Boot" "Restored file SHA-256 validation failed.\n\n${checksum_error:-Unknown checksum error}\n\nOperation log:\n$run_log_file"
    exit 1
fi
log_msg "Updated restored grub/grub.cfg unraiduuid to target ZFS pool GUID $pool_guid. EFI partitions were not modified."
status_msg "Synchronizing restored files to disk..."
if ! sync; then
    ui_msg "Restore Existing Internal Boot" "Unable to sync the restored boot filesystem."
    exit 1
fi
status_msg "Finalizing the restore..."
if ! zfs destroy "$snapshot_name"; then
    ui_msg "Restore Existing Internal Boot" "Unable to remove the restore rollback snapshot."
    exit 1
fi
snapshot_created=0
status_msg "Exporting the restored ZFS pool..."
if ! zpool export "$pool_name"; then
    ui_msg "Restore Existing Internal Boot" "The restore completed, but the '$pool_name' pool could not be exported. Export it before rebooting."
    exit 1
fi
pool_imported=0
rm -f -- "$staged_backup"
staged_backup=""
rmdir "$mount_root" 2>/dev/null || true
mount_root=""
ui_msg "Restore Complete" "Backup restored to the existing internal boot filesystem. The partition table and p4 user-data partition were not modified."
if ui_confirm "Restore Complete" "Restore completed successfully. Review the operation log now?" "y"; then
    view_log "Restore Operation Log" "$run_log_file"
fi
