#!/bin/bash
set -euo pipefail

ui_backend=""
INTERNAL_BOOT_SIZE_MIB="${INTERNAL_BOOT_SIZE_MIB:-8192}"
WIFI_MENU_ENABLED="${WIFI_MENU_ENABLED:-0}"

SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_MENU_LIB=""

for candidate in "${MENU_GUI_COMMON_LIB:-}" "/boot/install/menu_gui_common.sh" "$SCRIPT_SELF_DIR/menu_gui_common.sh"; do
    [[ -n "$candidate" ]] || continue
    if [[ -f "$candidate" ]]; then
        COMMON_MENU_LIB="$candidate"
        break
    fi
done

if [[ -z "$COMMON_MENU_LIB" ]]; then
    echo "Missing common menu library (menu_gui_common.sh)." >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$COMMON_MENU_LIB"

VERSION_CHECK_LIB="${VERSION_CHECK_LIB:-/boot/install/version_check.sh}"
# shellcheck disable=SC1090
[[ -f "$VERSION_CHECK_LIB" ]] && . "$VERSION_CHECK_LIB"
INSTALLER_UPDATE_WARNING_SHOWN=0

show_installer_update_warning() {
    local warning
    [[ "$INSTALLER_UPDATE_WARNING_SHOWN" -eq 0 ]] || return 0
    INSTALLER_UPDATE_WARNING_SHOWN=1
    warning="$(installer_update_warning 2>/dev/null || true)"
    if [[ -n "$warning" ]]; then
        ui_msg "Installer Update Available" "$warning"
    fi

    return 0
}

set_internal_boot_size() {
    local choice entered
    choice="$(ui_menu "Internal Boot Size" "Current: $(format_boot_size_label)" \
        A "Dedicated (reserve 1 MiB for p4)" \
        B "8G (8192 MiB)" \
        C "16G (16384 MiB)" \
        D "32G (32768 MiB)" \
        E "Custom")" || return 0

    case "$choice" in
        A) INTERNAL_BOOT_SIZE_MIB=0 ;;
        B) INTERNAL_BOOT_SIZE_MIB=8192 ;;
        C) INTERNAL_BOOT_SIZE_MIB=16384 ;;
        D) INTERNAL_BOOT_SIZE_MIB=32768 ;;
        E)
            entered="$(ui_prompt "Internal Boot Size" "Enter custom size in MiB (enter 0 for dedicated auto with 1 MiB reserved for p4, or >=1024)" "$INTERNAL_BOOT_SIZE_MIB")"
            entered="${entered//[[:space:]]/}"
            [[ -n "$entered" ]] || return 0
            if [[ "$entered" =~ ^[0-9]+$ ]] && (( entered == 0 || entered >= 1024 )); then
                INTERNAL_BOOT_SIZE_MIB="$entered"
            else
                ui_msg "Internal Boot Size" "Invalid size. Keeping $(format_boot_size_label)."
                return
            fi
            ;;
        *) return 0 ;;
    esac

    ui_msg "Internal Boot Size" "Internal boot size set to $(format_boot_size_label)."
}

user_zip_exists() {
    local zip_dirs=(
        "${PERSISTENT_ZIP_DIR:-/mnt/persist/zips}"
        "/mnt/persist/zip"
        "/run/onboarding-zips"
        "/tmp/onboarding-zips"
    )
    local d

    for d in "${zip_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        if compgen -G "$d/*.zip" > /dev/null; then
            return 0
        fi
    done

    return 1
}

main_menu_user() {
    local choice="" zip_missing=0 create_internal_label create_flash_label
    local prompt
    local wifi_label
    local wifi_available=0
    local wifi_present=0
    local wifi_enabled=0
    local -a menu_args

    show_installer_update_warning

    if [[ "$WIFI_MENU_ENABLED" == "1" ]]; then
        wifi_enabled=1
        if wifi_tools_available; then
            wifi_available=1
            wifi_label="Connect Wi-Fi + DHCP"
        else
            wifi_label="Connect Wi-Fi + DHCP (tools missing)"
        fi

        if wireless_iface_present; then
            wifi_present=1
        fi
    fi

    prompt=$'Type option key and press Enter'
    prompt+=$'\nInternal boot size: '"$(format_boot_size_label)"
    if ! user_zip_exists; then
        zip_missing=1
        prompt+=$'\nPlease download a zip first'
    fi

    if [[ "$zip_missing" -eq 1 ]]; then
        create_internal_label="Create Internal Boot (download zip first)"
        create_flash_label="Create Flash Boot (download zip first)"
    else
        create_internal_label="Create Internal Boot"
        create_flash_label="Create Flash Boot"
    fi

    menu_args=(
        A "Download ZIP"
        B "Set Internal Boot Size"
        C "$create_internal_label"
        D "$create_flash_label"
        E "Show Network Status"
        G "Retry Network (DHCP)"
        H "Shell"
        I "Resize Persistence"
        J "Refresh"
        K "Power Off"
        L "Reboot"
    )

    if [[ "$wifi_enabled" -eq 1 && "$wifi_present" -eq 1 ]]; then
        menu_args+=(F "$wifi_label")
    fi

    if ! choice="$(ui_menu "Unraid ISO Installer" "$prompt" "${menu_args[@]}")"; then
        choice="$(ui_hotkey_select "Unraid ISO Installer" "$prompt" "${menu_args[@]}")"
    fi
    choice="${choice//$'\r'/}"
    choice="${choice//[[:space:]]/}"
    choice="${choice^^}"

    case "$choice" in
        A) /bin/bash /boot/install/zip.sh --ui gui ;;
        B) set_internal_boot_size ;;
        C)
            if [[ "$zip_missing" -eq 1 ]]; then
                ui_msg "ZIP Required" "Please download a zip first."
            else
                /bin/bash /boot/install/create_internal_boot.sh --ui gui --size "$INTERNAL_BOOT_SIZE_MIB"
            fi
            ;;
        D)
            if [[ "$zip_missing" -eq 1 ]]; then
                ui_msg "ZIP Required" "Please download a zip first."
            else
                /bin/bash /boot/install/create_flash_boot.sh --ui gui
            fi
            ;;
        E) show_network_status ;;
        F)
            if [[ "$wifi_enabled" -ne 1 ]]; then
                ui_msg "Wi-Fi" "Wi-Fi is disabled in this build."
            elif [[ "$wifi_present" -ne 1 ]]; then
                ui_msg "Wi-Fi" "No wireless interface detected."
            elif [[ "$wifi_available" -eq 1 ]]; then
                connect_wifi_and_dhcp
            else
                ui_msg "Wi-Fi" "Wireless binaries are not available in this image."
            fi
            ;;
        G) retry_network ;;
        H) run_shell ;;
        I) run_resize_persistence ;;
        J) ;;
        K) ui_confirm "Power Off" "Power off this system now?" && do_poweroff ;;
        L) ui_confirm "Reboot" "Reboot this system now?" && do_reboot ;;
        *) ;;
    esac

    return 0
}

detect_ui_backend

if [[ "$ui_backend" == "text" ]]; then
    ui_msg "Unraid ISO Installer" "No dialog backend found (install 'whiptail' or 'dialog'). Using built-in text prompt mode."
fi

while true; do
    main_menu_user

    rc=$?
    if [[ $rc -eq 2 ]]; then
        break
    fi
done
