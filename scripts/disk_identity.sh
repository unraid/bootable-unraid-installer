#!/bin/bash

# Shared disk identity resolution for the internal boot installer.

sanitize_disk_id() {
    local raw="$1"
    local transport="${2:-}"

    # Keep USB IDs exactly as discovered.
    if [[ "$transport" == "usb" ]]; then
        printf '%s\n' "$raw"
        return 0
    fi

    printf '%s\n' "$raw" | sed -E 's/[[:space:]]+/_/g; s/[^[:alnum:]_.-]/_/g; s/^_+//; s/_+$//'
}

is_mmc_disk_name() {
    local disk_name="${1#/dev/}"

    [[ "$disk_name" =~ ^mmcblk[0-9]+$ ]]
}

resolve_mmc_disk_id() {
    local disk="$1"
    local disk_name="${disk#/dev/}"
    local sysfs_root="${DISK_ID_SYSFS_ROOT:-/sys/class/block}"
    local device_sysfs_path="${sysfs_root}/${disk_name}/device"
    local product_name=""
    local serial=""

    is_mmc_disk_name "$disk_name" || return 1

    # The eMMC product name is exposed by the MMC device, not reliably by
    # lsblk MODEL. Treat it as required because the runtime ID includes it.
    product_name="$(cat "${device_sysfs_path}/name" 2>/dev/null || true)"
    product_name="${product_name//\\x20/ }"
    product_name="$(sanitize_disk_id "$product_name" mmc)"
    [[ -n "$product_name" && "$product_name" != "-" ]] || return 1

    if command -v udevadm >/dev/null 2>&1; then
        # Prefer ID_SERIAL because it preserves the serial representation used
        # by the current installer fallback, including a 0x prefix.
        serial="$(udevadm info --query=property --name "$disk" 2>/dev/null | awk -F= '/^ID_SERIAL=/{print $2; exit}')"
        if [[ -z "$serial" ]]; then
            serial="$(udevadm info --query=property --name "$disk" 2>/dev/null | awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}')"
        fi
    fi
    if [[ -z "$serial" ]]; then
        serial="$(lsblk -dn -o SERIAL "$disk" 2>/dev/null | head -n1 || true)"
    fi

    serial="${serial//\\x20/ }"
    serial="$(sanitize_disk_id "$serial" mmc)"
    [[ -n "$serial" && "$serial" != "-" ]] || return 1

    if [[ "$serial" == "${product_name}_"* ]]; then
        printf '%s\n' "$serial"
    else
        printf '%s\n' "${product_name}_${serial}"
    fi
}

resolve_disk_id() {
    local disk="$1"
    local id=""
    local link resolved
    local transport=""
    local model=""
    local short_serial=""

    if declare -F resolve_identity_map_id >/dev/null 2>&1; then
        id="$(resolve_identity_map_id "$disk" || true)"
        if [[ -n "$id" ]]; then
            printf '%s\n' "$id"
            return 0
        fi
    fi
    if [[ -n "${IDENTITY_MAP_FILE:-}" ]]; then
        return 1
    fi

    transport="$(lsblk -dn -o TRAN "$disk" 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n1 || true)"
    if is_mmc_disk_name "$disk"; then
        resolve_mmc_disk_id "$disk"
        return $?
    fi

    if [[ "$transport" != "usb" ]]; then
        model="$(lsblk -dn -o MODEL "$disk" 2>/dev/null | head -n1 || true)"
        model="${model//\\x20/ }"
        model="$(sanitize_disk_id "$model" "$transport")"

        if command -v udevadm >/dev/null 2>&1; then
            short_serial="$(udevadm info --query=property --name "$disk" 2>/dev/null | awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}')"
        fi
        if [[ -z "$short_serial" ]]; then
            short_serial="$(lsblk -dn -o SERIAL "$disk" 2>/dev/null | head -n1 || true)"
        fi
        short_serial="${short_serial//\\x20/ }"
        short_serial="$(sanitize_disk_id "$short_serial" "$transport")"

        if [[ -n "$model" && -n "$short_serial" ]]; then
            id="${model}_${short_serial}"
            id="$(sanitize_disk_id "$id" "$transport")"
            printf '%s\n' "$id"
            return 0
        fi
    fi

    if command -v udevadm >/dev/null 2>&1; then
        id="$(udevadm info --query=property --name "$disk" 2>/dev/null | awk -F= '/^ID_SERIAL=/{print $2; exit}')"
        if [[ -n "$id" ]]; then
            id="$(sanitize_disk_id "$id" "$transport")"
            printf '%s\n' "$id"
            return 0
        fi
        id="$(udevadm info --query=property --name "$disk" 2>/dev/null | awk -F= '/^ID_WWN=/{print $2; exit}')"
        if [[ -n "$id" ]]; then
            id="$(sanitize_disk_id "$id" "$transport")"
            printf '%s\n' "$id"
            return 0
        fi
    fi

    for link in /dev/disk/by-id/*; do
        [[ -e "$link" ]] || continue
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        if [[ "$resolved" == "$disk" ]]; then
            id="$(basename "$link")"
            id="$(sanitize_disk_id "$id" "$transport")"
            printf '%s\n' "$id"
            return 0
        fi
    done

    id="$(lsblk -dn -o WWN,SERIAL "$disk" 2>/dev/null | awk '{
        for (field = 1; field <= 2; field++) {
            if ($field != "" && $field != "-") {
                print $field
                exit
            }
        }
    }' || true)"
    id="$(sanitize_disk_id "$id" "$transport")"
    if [[ -n "$id" && "$id" != "-" ]]; then
        printf '%s\n' "$id"
        return 0
    fi

    return 1
}
