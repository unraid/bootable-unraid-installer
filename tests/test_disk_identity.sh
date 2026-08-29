#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$repo_root/scripts/disk_identity.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    [[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

fixture_root="$(mktemp -d /tmp/bootable-unraid-installer-test.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p \
    "$fixture_root/bin" \
    "$fixture_root/sys/class/block/mmcblk0/device" \
    "$fixture_root/sys/class/block/mmcblk1/device" \
    "$fixture_root/sys/class/block/mmcblk2/device"

printf '%s\n' 'ARV11X' > "$fixture_root/sys/class/block/mmcblk0/device/name"
printf '%s\n' 'ARV11X' > "$fixture_root/sys/class/block/mmcblk1/device/name"

cat > "$fixture_root/bin/udevadm" <<'EOF'
#!/bin/bash

case "$*" in
    */dev/mmcblk0*)
        printf '%s\n' 'ID_SERIAL=0x8a95166f' 'ID_SERIAL_SHORT=0x8a95166f'
        ;;
    */dev/mmcblk1*)
        printf '%s\n' 'ID_SERIAL=ARV11X_0x8a951670' 'ID_SERIAL_SHORT='
        ;;
    */dev/mmcblk2*)
        printf '%s\n' 'ID_SERIAL=0x8a951671' 'ID_SERIAL_SHORT=0x8a951671'
        ;;
    */dev/nvme0n1*)
        printf '%s\n' 'ID_SERIAL=nvme-NVME123' 'ID_SERIAL_SHORT=NVME123'
        ;;
    */dev/sda*)
        printf '%s\n' 'ID_SERIAL=sata-SATA123' 'ID_SERIAL_SHORT=SATA123'
        ;;
esac
EOF
chmod +x "$fixture_root/bin/udevadm"

cat > "$fixture_root/bin/lsblk" <<'EOF'
#!/bin/bash

case "$*" in
    *'-o TRAN /dev/mmcblk0'*) printf '%s\n' 'mmc' ;;
    *'-o TRAN /dev/mmcblk1'*) printf '%s\n' 'mmc' ;;
    *'-o TRAN /dev/mmcblk2'*) printf '%s\n' 'mmc' ;;
    *'-o TRAN /dev/nvme0n1'*) printf '%s\n' 'nvme' ;;
    *'-o TRAN /dev/sda'*) printf '%s\n' 'sata' ;;
    *'-o MODEL /dev/nvme0n1'*) printf '%s\n' 'NVMe Test Model' ;;
    *'-o MODEL /dev/sda'*) printf '%s\n' 'SATA Test Model' ;;
    *'-o SERIAL /dev/nvme0n1'*) printf '%s\n' 'NVME123' ;;
    *'-o SERIAL /dev/sda'*) printf '%s\n' 'SATA123' ;;
    *) printf '%s\n' '' ;;
esac
EOF
chmod +x "$fixture_root/bin/lsblk"

export PATH="$fixture_root/bin:$PATH"
export DISK_ID_SYSFS_ROOT="$fixture_root/sys/class/block"

assert_eq \
    'ARV11X_0x8a95166f' \
    "$(resolve_disk_id /dev/mmcblk0)" \
    'eMMC identity must include the product name'

assert_eq \
    'ARV11X_0x8a951670' \
    "$(resolve_disk_id /dev/mmcblk1)" \
    'an already-prefixed eMMC serial must not be prefixed twice'

if resolve_disk_id /dev/mmcblk2 >/dev/null 2>&1; then
    fail 'eMMC identity resolution must fail when the product name is missing'
fi

assert_eq \
    'NVMe_Test_Model_NVME123' \
    "$(resolve_disk_id /dev/nvme0n1)" \
    'NVMe identity must retain the generic model-plus-serial path'

assert_eq \
    'SATA_Test_Model_SATA123' \
    "$(resolve_disk_id /dev/sda)" \
    'conventional disk identity must retain the generic model-plus-serial path'

resolve_identity_map_id() {
    [[ "$1" == "/dev/nvme0n1" ]] || return 1
    printf '%s\n' 'PHYSICAL_NVME_ID'
}
IDENTITY_MAP_FILE="$fixture_root/physical-disk-map"
: > "$IDENTITY_MAP_FILE"

assert_eq \
    'PHYSICAL_NVME_ID' \
    "$(resolve_disk_id /dev/nvme0n1)" \
    'a physical-disk handoff must override the guest-visible identity'

if resolve_disk_id /dev/sda >/dev/null 2>&1; then
    fail 'an active physical-disk handoff must reject disks that are not mapped'
fi

printf '%s\n' 'PASS: disk identity regression tests'
