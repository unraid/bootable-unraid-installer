#!/bin/bash
# Reconcile only this VM image's boot-pool assignment before emhttp starts.
set -euo pipefail

main() {
    local boot_root="${1:-/boot}" source pool partition parent disk_id cfg temporary
    local -a members
    source="$(findmnt -n -o SOURCE --target "$boot_root")"
    [[ "$source" == flash/boot ]] || { echo 'VM boot identity: unexpected boot dataset' >&2; return 1; }
    pool="${source%%/*}"
    mapfile -t members < <(zpool status -LP "$pool" | awk '$1 ~ /^\/dev\// {print $1}')
    [[ ${#members[@]} == 1 ]] || { echo 'VM boot identity: expected one boot-pool device' >&2; return 1; }
    partition="$(readlink -f "${members[0]}")"
    parent="$(lsblk -dn -o PKNAME "$partition")"
    [[ "$parent" =~ ^[a-zA-Z0-9]+$ ]] || { echo 'VM boot identity: cannot identify parent disk' >&2; return 1; }
    # Use the same canonical model/serial resolution as the installer.
    # shellcheck disable=SC1091
    source "$boot_root/config/vm-image/disk_identity.sh"
    disk_id="$(resolve_disk_id "/dev/$parent")"
    [[ "$disk_id" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo 'VM boot identity: disk has no usable identity' >&2; return 1; }
    cfg="$boot_root/config/pools/boot.cfg"
    [[ -f "$cfg" && ! -L "$cfg" ]] || return 1
    [[ $(grep -c '^diskId=' "$cfg") == 1 ]] || return 1
    if grep -q '^diskId\.' "$cfg"; then
        echo 'VM boot identity: multiple configured boot devices are unsupported' >&2
        return 1
    fi
    if grep -Fqx "diskId=\"$disk_id\"" "$cfg"; then
        return 0
    fi
    temporary="$(mktemp "${cfg}.XXXXXX")"
    if ! sed "s/^diskId=.*/diskId=\"$disk_id\"/" "$cfg" > "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    chmod --reference="$cfg" "$temporary"
    mv -f "$temporary" "$cfg"
    sync -f "$cfg"
    echo "VM boot identity: assigned $parent to the boot pool"
}

main "$@"
