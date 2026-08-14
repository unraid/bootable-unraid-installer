#!/bin/bash

format_boot_size_label() {
    if (( INTERNAL_BOOT_SIZE_MIB == 0 )); then
        printf '%s\n' "Dedicated"
    else
        printf '%s MiB\n' "$INTERNAL_BOOT_SIZE_MIB"
    fi
}

ui_calc_dims() {
    local kind="$1"
    local rows cols height width list_height

    rows="$(tput lines 2>/dev/null || echo 24)"
    cols="$(tput cols 2>/dev/null || echo 80)"

    (( rows < 20 )) && rows=20
    (( cols < 70 )) && cols=70

    case "$kind" in
        msg|confirm)
            height=$((rows - 6))
            width=$((cols - 8))
            (( height < 10 )) && height=10
            (( height > 30 )) && height=30
            (( width < 60 )) && width=60
            (( width > 160 )) && width=160
            printf '%s %s\n' "$height" "$width"
            ;;
        input)
            height=$((rows - 4))
            width=$((cols - 6))
            (( height < 12 )) && height=12
            (( height > 32 )) && height=32
            (( width < 70 )) && width=70
            (( width > 180 )) && width=180
            printf '%s %s\n' "$height" "$width"
            ;;
        menu)
            height=$((rows - 4))
            width=$((cols - 6))
            (( height < 18 )) && height=18
            (( height > 36 )) && height=36
            (( width < 80 )) && width=80
            (( width > 180 )) && width=180
            list_height=$((height - 10))
            (( list_height < 8 )) && list_height=8
            (( list_height > 20 )) && list_height=20
            printf '%s %s %s\n' "$height" "$width" "$list_height"
            ;;
    esac
}

ui_set_dims() {
    local kind="$1"
    local default_1="$2"
    local default_2="$3"
    local default_3="${4:-}"
    local dims
    local dim_1 dim_2 dim_3

    dims="$(ui_calc_dims "$kind" 2>/dev/null || true)"
    read -r dim_1 dim_2 dim_3 <<< "$dims"

    UI_DIM_1="${dim_1:-$default_1}"
    UI_DIM_2="${dim_2:-$default_2}"
    if [[ -n "$default_3" ]]; then
        UI_DIM_3="${dim_3:-$default_3}"
    fi
}

wifi_tools_available() {
    if ! command -v ip >/dev/null 2>&1; then
        return 1
    fi

    if ! command -v dhclient >/dev/null 2>&1 && ! command -v udhcpc >/dev/null 2>&1; then
        return 1
    fi

    if command -v nmcli >/dev/null 2>&1; then
        return 0
    fi

    if command -v iw >/dev/null 2>&1 && command -v wpa_supplicant >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

wireless_iface_present() {
    if command -v iw >/dev/null 2>&1; then
        if iw dev 2>/dev/null | awk '$1=="Interface"{found=1} END{exit !found}'; then
            return 0
        fi
    fi

    local dev
    for dev in /sys/class/net/*; do
        [[ -d "$dev/wireless" ]] && return 0
    done

    return 1
}

ui_msg() {
    local title="$1"
    local message="$2"
    local h w

    case "$ui_backend" in
        whiptail)
            ui_set_dims msg 16 80
            h="$UI_DIM_1"
            w="$UI_DIM_2"
            whiptail --title "$title" --msgbox "$message" "$h" "$w"
            ;;
        dialog)
            ui_set_dims msg 16 80
            h="$UI_DIM_1"
            w="$UI_DIM_2"
            dialog --title "$title" --msgbox "$message" "$h" "$w"
            ;;
        *)
            echo "[$title]"
            echo
            echo "$message"
            echo
            read -r -p "Press Enter to continue..." _
            ;;
    esac
}

detect_ui_backend() {
    local preferred="${MENU_BACKEND:-}"

    case "$preferred" in
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
            ui_msg "Menu Backend" "Unknown MENU_BACKEND '$preferred' (expected: whiptail|dialog|text)."
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

ui_brand_banner() {
    local cols width indent

    cols="${UI_BRAND_COLS:-$(tput cols 2>/dev/null || echo 80)}"
    width=$((cols - 6))
    (( width > 180 )) && width=180
    (( width < 70 )) && width=70
    indent=$(((width - 42) / 2))
    (( indent < 0 )) && indent=0

    brand_line() {
        printf '%*s|%-40s|\n' "$indent" '' "$1"
    }

    printf '%*s%s\n' "$indent" '' '+----------------------------------------+'
    brand_line '                            |'
    brand_line '                        |      |'
    brand_line '    |               |   |      |   |'
    brand_line '    |               |              |'
    brand_line '    |   |       |   |              |'
    brand_line '        |       |'
    brand_line '            |'
    brand_line '              U N R A I D'
    printf '%*s%s\n' "$indent" '' '+----------------------------------------+'
}

ui_center_text() {
    local text="$1"
    local width="${2:-84}"
    local line length padding

    while IFS= read -r line; do
        length=${#line}
        padding=$(( (width - length) / 2 ))
        (( padding < 0 )) && padding=0
        printf '%*s%s\n' "$padding" '' "$line"
    done <<< "$text"
}

ui_brand_logo() {
    cat <<'EOF'
                            |
                        |       |
    |               |   |       |   |
    |               |               |
    |   |       |   |               |
        |       |
            |

               U N R A I D
EOF
}

ui_menu_with_brand() {
    local title="$1"
    local prompt="$2"
    local rows cols logo_width logo_height logo_x menu_x menu_y menu_width menu_height list_height out rc
    shift 2

    if [[ "$ui_backend" != "dialog" ]]; then
        if [[ "$ui_backend" == "whiptail" ]]; then
            local h w list_h terminal_rows
            # Reserve enough vertical space for the complete banner, prompt,
            # and menu entries.  A short fixed box clips the banner in Newt.
            terminal_rows="$(tput lines 2>/dev/null || echo 24)"
            h=$((terminal_rows - 4))
            (( h < 28 )) && h=28
            (( h > 36 )) && h=36
            w=90
            list_h=12
            # Whiptail reserves a few columns inside the 90-column box.
            # Use its effective content width so the logo is truly centred.
            UI_BRAND_COLS=90
            whiptail --title "$title" --menu "$(ui_brand_banner)"$'\n'"$prompt" "$h" "$w" "$list_h" "$@" 3>&1 1>&2 2>&3
            return
        fi
        ui_menu "$title" "$(ui_brand_banner)"$'\n'"$prompt" "$@"
        return
    fi

    rows="$(tput lines 2>/dev/null || echo 24)"
    cols="$(tput cols 2>/dev/null || echo 80)"
    logo_width=36
    logo_height=10
    menu_width=100
    (( menu_width > cols - 8 )) && menu_width=$((cols - 8))
    (( menu_width < 70 )) && menu_width=70
    menu_height=$((rows - 13))
    (( menu_height < 18 )) && menu_height=18
    (( menu_height > 28 )) && menu_height=28
    list_height=$((menu_height - 8))
    (( list_height < 8 )) && list_height=8
    logo_x=$(((cols - logo_width) / 2))
    menu_x=$(((cols - menu_width) / 2))
    menu_y=11

    out="$(dialog --stdout \
        --begin 1 "$logo_x" --title "UNRAID" --infobox "$(ui_brand_logo)" "$logo_height" "$logo_width" \
        --and-widget \
        --begin "$menu_y" "$menu_x" --title "$title" --menu "$prompt" "$menu_height" "$menu_width" "$list_height" "$@")"
    rc=$?
    [[ $rc -eq 0 ]] || return "$rc"
    printf '%s\n' "$out"
}

ui_prompt() {
    local title="$1"
    local prompt="$2"
    local default_value="${3:-}"
    local h w

    case "$ui_backend" in
        whiptail)
            ui_set_dims input 12 80
            h="$UI_DIM_1"
            w="$UI_DIM_2"
            whiptail --title "$title" --inputbox "$prompt" "$h" "$w" "$default_value" 3>&1 1>&2 2>&3 || true
            ;;
        dialog)
            local out
            ui_set_dims input 12 80
            h="$UI_DIM_1"
            w="$UI_DIM_2"
            out="$(dialog --title "$title" --inputbox "$prompt" "$h" "$w" "$default_value" 3>&1 1>&2 2>&3)" || true
            printf '%s\n' "$out"
            ;;
        *)
            local ans
            read -r -p "$prompt: " ans || true
            printf '%s\n' "${ans:-$default_value}"
            ;;
    esac
}

ui_confirm() {
    local title="$1"
    local message="$2"
    local h w

    case "$ui_backend" in
        whiptail)
            ui_set_dims confirm 12 80
            h="$UI_DIM_1"
            w="$UI_DIM_2"
            whiptail --title "$title" --yesno "$message" "$h" "$w"
            ;;
        dialog)
            ui_set_dims confirm 12 80
            h="$UI_DIM_1"
            w="$UI_DIM_2"
            dialog --title "$title" --yesno "$message" "$h" "$w"
            local rc=$?
            return "$rc"
            ;;
        *)
            read -r -p "$message [y/N]: " ans || true
            ans="${ans,,}"
            [[ "$ans" == "y" || "$ans" == "yes" ]]
            ;;
    esac
}

ui_menu() {
    local title="$1"
    local prompt="$2"
    local h w list_h
    shift 2

    case "$ui_backend" in
        whiptail)
            ui_set_dims menu 22 100 12
            h="$UI_DIM_1"
            w="$UI_DIM_2"
            list_h="$UI_DIM_3"
            whiptail --title "$title" --menu "$prompt" "$h" "$w" "$list_h" "$@" 3>&1 1>&2 2>&3
            ;;
        dialog)
            local out
            ui_set_dims menu 22 100 12
            h="$UI_DIM_1"
            w="$UI_DIM_2"
            list_h="$UI_DIM_3"
            out="$(dialog --stdout --title "$title" --menu "$prompt" "$h" "$w" "$list_h" "$@")"
            local rc=$?
            [[ $rc -eq 0 ]] || return "$rc"
            printf '%s\n' "$out"
            ;;
        *)
            return 1
            ;;
    esac
}

ui_hotkey_select() {
    local title="$1"
    local prompt="$2"
    shift 2

    local lines=""
    local tag=""
    local desc=""
    local choice=""

    while (($#)); do
        tag="$1"
        desc="${2:-}"
        shift 2 || true
        lines+="${tag}) ${desc}\\n"
    done

    choice="$(ui_prompt "$title" "${prompt}\\n\\n${lines}\\nEnter option key:" "")"
    choice="${choice//[[:space:]]/}"
    printf '%s\n' "$choice"
}

do_poweroff() {
    sync || true

    command -v poweroff >/dev/null 2>&1 && exec poweroff
    [ -x /sbin/poweroff ] && exec /sbin/poweroff
    command -v shutdown >/dev/null 2>&1 && exec shutdown -h now
    [ -x /sbin/shutdown ] && exec /sbin/shutdown -h now
    command -v halt >/dev/null 2>&1 && exec halt -f
    [ -x /sbin/halt ] && exec /sbin/halt -f
    command -v busybox >/dev/null 2>&1 && exec busybox poweroff -f

    if [ -w /proc/sys/kernel/sysrq ]; then
        echo 1 > /proc/sys/kernel/sysrq || true
    fi
    if [ -w /proc/sysrq-trigger ]; then
        echo o > /proc/sysrq-trigger || true
    fi

    ui_msg "Power Off" "Unable to power off automatically on this runtime."
    return 1
}

do_reboot() {
    sync || true

    command -v reboot >/dev/null 2>&1 && exec reboot
    [ -x /sbin/reboot ] && exec /sbin/reboot
    command -v shutdown >/dev/null 2>&1 && exec shutdown -r now
    [ -x /sbin/shutdown ] && exec /sbin/shutdown -r now
    command -v busybox >/dev/null 2>&1 && exec busybox reboot -f

    if [ -w /proc/sys/kernel/sysrq ]; then
        echo 1 > /proc/sys/kernel/sysrq || true
    fi
    if [ -w /proc/sysrq-trigger ]; then
        echo b > /proc/sysrq-trigger || true
    fi

    ui_msg "Reboot" "Unable to reboot automatically on this runtime."
    return 1
}

retry_network() {
    local iface success
    success=0

    load_nic_modules_from_modalias() {
        local alias_file
        for alias_file in /sys/bus/pci/devices/*/modalias /sys/bus/usb/devices/*/modalias; do
            [ -r "$alias_file" ] || continue
            modprobe -ab "$(cat "$alias_file")" 2>/dev/null || true
        done
    }

    trigger_device_discovery() {
        if command -v udevadm >/dev/null 2>&1; then
            udevadm trigger --type=subsystems --action=add || true
            udevadm trigger --type=devices --action=add || true
            udevadm settle || true
        fi
    }

    list_candidate_ifaces() {
        local dev
        for dev in /sys/class/net/*; do
            [ -e "$dev" ] || continue
            dev="${dev##*/}"
            case "$dev" in
                lo|sit*|ip6tnl*|tunl*|dummy*|bonding_masters)
                    continue
                    ;;
            esac
            echo "$dev"
        done
    }

    if ! command -v ip >/dev/null 2>&1; then
        ui_msg "Network" "'ip' command not found; cannot retry network setup."
        return 1
    fi

    if ! command -v dhclient >/dev/null 2>&1 && ! command -v udhcpc >/dev/null 2>&1; then
        ui_msg "Network" "No DHCP client found ('dhclient' or 'udhcpc')."
        return 1
    fi

    trigger_device_discovery
    if [ "$(list_candidate_ifaces | wc -l)" -eq 0 ]; then
        load_nic_modules_from_modalias
        trigger_device_discovery
    fi

    for iface in $(list_candidate_ifaces); do
        ip link set "$iface" up || true

        if command -v dhclient >/dev/null 2>&1; then
            dhclient -4 -1 -v "$iface" || true
        elif command -v udhcpc >/dev/null 2>&1; then
            udhcpc -n -q -i "$iface" || true
        fi

        if ip -4 -o addr show dev "$iface" scope global | grep -q .; then
            success=1
            if ip route | grep -q '^default '; then
                break
            fi
        fi
    done

    if [ "$success" -eq 1 ] && ip route | grep -q '^default '; then
        ui_msg "Network" "Network configured successfully."
        return 0
    fi

    ui_msg "Network" "DHCP attempts completed but no usable IPv4/default route was detected."
    return 1
}

connect_wifi_and_dhcp() {
    local ssid pass wifi_iface conf_file scan ssid_count ssid_entry choice
    local -a menu_args

    if ! command -v ip >/dev/null 2>&1; then
        ui_msg "Wi-Fi" "'ip' command not found; cannot configure Wi-Fi."
        return 1
    fi

    if command -v nmcli >/dev/null 2>&1; then
        scan="$(nmcli -t -f SSID dev wifi list 2>/dev/null | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | awk 'NF && !seen[$0]++' | head -n 20 || true)"
        ssid=""
        if [[ -n "$scan" ]]; then
            ssid_count=0
            menu_args=()
            while IFS= read -r ssid_entry; do
                [[ -n "$ssid_entry" ]] || continue
                ssid_count=$((ssid_count + 1))
                menu_args+=("$ssid_count" "$ssid_entry")
            done <<< "$scan"

            if (( ssid_count > 0 )); then
                menu_args+=("M" "Enter SSID manually")
                choice="$(ui_menu "Wi-Fi SSID" "Select Wi-Fi network" "${menu_args[@]}")" || choice="M"
                choice="${choice//$'\r'/}"
                choice="${choice//[[:space:]]/}"
                choice="${choice^^}"
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ssid_count )); then
                    ssid="${menu_args[$(( (choice - 1) * 2 + 1 ))]}"
                fi
            fi
        fi

        if [[ -z "$ssid" ]]; then
            ssid="$(ui_prompt "Wi-Fi" "Enter Wi-Fi SSID" "")"
        fi
        ssid="$(printf '%s' "$ssid" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        [[ -n "${ssid//[[:space:]]/}" ]] || {
            ui_msg "Wi-Fi" "SSID is required."
            return 1
        }

        pass="$(ui_prompt "Wi-Fi" "Enter Wi-Fi password (leave blank for open network)" "")"

        nmcli radio wifi on >/dev/null 2>&1 || true
        if [[ -n "$pass" ]]; then
            nmcli dev wifi connect "$ssid" password "$pass" >/dev/null 2>&1 || {
                ui_msg "Wi-Fi" "Failed to connect to '$ssid'."
                return 1
            }
        else
            nmcli dev wifi connect "$ssid" >/dev/null 2>&1 || {
                ui_msg "Wi-Fi" "Failed to connect to '$ssid'."
                return 1
            }
        fi

        retry_network
        return $?
    fi

    if ! command -v iw >/dev/null 2>&1 || ! command -v wpa_supplicant >/dev/null 2>&1; then
        ui_msg "Wi-Fi" "Wi-Fi tools missing. Install 'nmcli' or 'iw' + 'wpa_supplicant'."
        return 1
    fi

    wifi_iface="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')"
    if [[ -z "$wifi_iface" ]]; then
        local dev
        for dev in /sys/class/net/*; do
            [[ -d "$dev/wireless" ]] || continue
            wifi_iface="${dev##*/}"
            break
        done
    fi
    [[ -n "$wifi_iface" ]] || {
        ui_msg "Wi-Fi" "No Wi-Fi interface detected."
        return 1
    }

    ssid="$(ui_prompt "Wi-Fi" "Enter Wi-Fi SSID" "")"
    [[ -n "${ssid//[[:space:]]/}" ]] || {
        ui_msg "Wi-Fi" "SSID is required."
        return 1
    }

    pass="$(ui_prompt "Wi-Fi" "Enter Wi-Fi password (leave blank for open network)" "")"

    conf_file="$(mktemp)"
    if [[ -n "$pass" ]]; then
        if command -v wpa_passphrase >/dev/null 2>&1; then
            wpa_passphrase "$ssid" "$pass" > "$conf_file"
        else
            cat > "$conf_file" <<EOF
network={
    ssid="$ssid"
    psk="$pass"
}
EOF
        fi
    else
        cat > "$conf_file" <<EOF
network={
    ssid="$ssid"
    key_mgmt=NONE
}
EOF
    fi

    if command -v pkill >/dev/null 2>&1; then
        pkill -f "wpa_supplicant.*${wifi_iface}" >/dev/null 2>&1 || true
    fi

    ip link set "$wifi_iface" up || true
    if ! wpa_supplicant -B -i "$wifi_iface" -c "$conf_file" >/dev/null 2>&1; then
        rm -f "$conf_file"
        ui_msg "Wi-Fi" "wpa_supplicant failed on '$wifi_iface'."
        return 1
    fi
    rm -f "$conf_file"

    if command -v dhclient >/dev/null 2>&1; then
        dhclient -4 -1 -v "$wifi_iface" >/dev/null 2>&1 || true
    elif command -v udhcpc >/dev/null 2>&1; then
        udhcpc -n -q -i "$wifi_iface" >/dev/null 2>&1 || true
    fi

    if ip -4 -o addr show dev "$wifi_iface" scope global | grep -q . && ip route | grep -q '^default '; then
        ui_msg "Wi-Fi" "Wi-Fi connected and DHCP configured on '$wifi_iface'."
        return 0
    fi

    ui_msg "Wi-Fi" "Wi-Fi association completed, but DHCP/default route is still missing."
    return 1
}

show_network_status() {
    local tmp
    tmp="$(mktemp)"

    {
        if command -v ip >/dev/null 2>&1; then
            echo "[Interfaces]"
            ip -br link
            echo
            echo "[IP Addresses]"
            ip -br addr
            echo
            echo "[Routes]"
            ip route
        else
            echo "'ip' command not found."
            echo
            echo "[Interfaces (/proc/net/dev)]"
            cat /proc/net/dev
            echo
            echo "[Routes (/proc/net/route)]"
            cat /proc/net/route
        fi
    } > "$tmp"

    ui_msg "Network Status" "$(cat "$tmp")"
    rm -f "$tmp"
}

run_shell() {
    clear
    echo "Launching interactive shell. Exit shell to return to menu."
    if command -v cttyhack >/dev/null 2>&1; then
        /bin/busybox cttyhack /bin/bash -i
    else
        /bin/bash -i </dev/tty0 >/dev/tty0 2>&1
    fi
}

run_resize_persistence() {
    local resize_tool="/usr/local/sbin/resize_persistence.sh"
    local output=""
    local progress_text=""
    local progress_file=""
    local pid=""
    local rc=0

    if [[ ! -x "$resize_tool" ]]; then
        ui_msg "Resize Persistence" "Resize utility not available: $resize_tool"
        return 1
    fi

    progress_file="$(mktemp /tmp/resize-progress.XXXXXX)"

    "$resize_tool" >"$progress_file" 2>&1 &
    pid="$!"

    while kill -0 "$pid" >/dev/null 2>&1; do
        progress_text="$(tail -n 6 "$progress_file" 2>/dev/null || true)"
        case "$ui_backend" in
            whiptail)
                whiptail --title "Resize Persistence" --infobox "Resizing persistence...\n\n${progress_text:-Starting...}" 14 90
                ;;
            dialog)
                dialog --title "Resize Persistence" --infobox "Resizing persistence...\n\n${progress_text:-Starting...}" 14 90
                ;;
            *)
                ;;
        esac
        sleep 1
    done

    wait "$pid" || rc=$?
    output="$(cat "$progress_file" 2>/dev/null || true)"
    rm -f "$progress_file"

    if [[ "$ui_backend" == "dialog" ]]; then
        clear
    fi

    if [[ $rc -eq 0 ]]; then
        ui_msg "Resize Persistence" "Resize completed successfully.\n\n${output:-No output.}"
        return 0
    fi

    if [[ -z "$output" ]]; then
        output="No output from resize helper. Exit code: $rc"
    else
        output="$output\n\nExit code: $rc"
    fi

    ui_msg "Resize Persistence" "Resize failed.\n\n${output}"
    return 1
}
