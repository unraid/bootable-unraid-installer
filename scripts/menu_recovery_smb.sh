#!/bin/bash
set -euo pipefail

# shellcheck disable=SC2034 # Consumed by the sourced menu library.
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

share_dir="/mnt/persist/recovery-backups"
installer_zip_dir="/mnt/persist/zips"
runtime_dir="/run/unraid-recovery-smb"

if ! mountpoint -q /mnt/persist; then
    ui_msg "SMB Backup Share" "Persistent storage is not mounted."
    exit 1
fi
if ! command -v smbd >/dev/null 2>&1; then
    ui_msg "SMB Backup Share" "Samba is not available in this installer image."
    exit 1
fi

ip_address="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1 {split($4, a, "/"); print a[1]}')"
if [[ -z "$ip_address" ]]; then
    ui_msg "SMB Backup Share" "No network IPv4 address is configured. Connect the installer to the network first."
    exit 1
fi

if [[ -f "$runtime_dir/smbd.pid" ]] && kill -0 "$(cat "$runtime_dir/smbd.pid")" 2>/dev/null; then
    ui_msg "SMB Backup Share" "The backup share is already running.\n\nPath: \\\\$ip_address\\Unraid-Recovery\nFolder: $share_dir"
    exit 0
fi

if ! ui_confirm "Enable SMB Backup Share" "Delete installer ZIPs from $installer_zip_dir and start a temporary guest-writable SMB share? Anyone on this network can write to it until the installer reboots."; then
    exit 0
fi

mkdir -p /run/samba/ncalrpc "$share_dir" "$runtime_dir"
chmod 0700 /run/samba/ncalrpc
chmod 0700 "$share_dir"
if [[ -d "$installer_zip_dir" ]] && ! find "$installer_zip_dir" -maxdepth 1 -type f -iname '*.zip' -delete; then
    ui_msg "SMB Backup Share" "Unable to remove installer ZIPs from $installer_zip_dir."
    exit 1
fi
guest_user="nobody"
if ! chown nobody:nogroup "$share_dir" 2>/dev/null; then
    # Some persistent-storage filesystems do not support POSIX ownership.
    # Samba must use root there because the directory cannot be made writable
    # by the unprivileged guest account.
    guest_user="root"
fi
cat > "$runtime_dir/smb.conf" <<EOF
[global]
  security = user
  map to guest = Bad User
  guest account = $guest_user
  pid directory = $runtime_dir
  lock directory = $runtime_dir
  state directory = $runtime_dir
  private dir = $runtime_dir
  log file = $runtime_dir/smbd.log
  server min protocol = SMB2

[Unraid-Recovery]
  path = $share_dir
  read only = no
  guest ok = yes
  force user = $guest_user
  browseable = yes
EOF

smbd --foreground --no-process-group --configfile="$runtime_dir/smb.conf" >"$runtime_dir/smbd.log" 2>&1 &
echo "$!" > "$runtime_dir/smbd.pid"
sleep 1
if ! kill -0 "$(cat "$runtime_dir/smbd.pid")" 2>/dev/null; then
    ui_msg "SMB Backup Share" "Unable to start Samba.\n\n$(tail -n 10 "$runtime_dir/smbd.log" 2>/dev/null || true)"
    exit 1
fi

ui_msg "SMB Backup Share Enabled" "Copy the backup ZIP to:\n\n\\\\$ip_address\\Unraid-Recovery\n\nThis share permits guest uploads and remains available until this installer reboots."
