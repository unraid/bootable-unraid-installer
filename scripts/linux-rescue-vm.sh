#!/bin/bash
# Start the official Unraid Installer ISO in a temporary KVM guest while
# passing physical host disks through for an eventual bare-metal boot.

set -euo pipefail

ISO=""
RELEASE_TAG=""
PUBLISHED_RELEASE_TAG=""
RELEASE_REPOSITORY="${UNRAID_INSTALLER_RELEASE_REPOSITORY:-unraid/bootable-unraid-installer}"
QEMU_BIN="${UNRAID_INSTALLER_QEMU_BIN:-}"
STATE_DIR="/root/unraid-installer-vm"
RAM_MIB="8192"
VCPUS="4"
VNC_DISPLAY="1"
DISKS=()

usage() {
    cat <<'EOF'
Usage:
  linux-rescue-vm.sh [--disk DEVICE] [--disk DEVICE] [options]

Options:
  --disk DEVICE       Physical whole disk; repeat for a two-disk mirror
                      Omit to choose interactively from idle whole disks
  --iso PATH          Use a local installer ISO instead of downloading one
  --release-tag TAG   Download the online ISO from this Installer-* release
  --state-dir PATH    VM state directory (default: /root/unraid-installer-vm)
  --ram MIB           Guest memory in MiB (default: 8192)
  --cpus COUNT        Guest vCPU count (default: 4)
  --vnc-display N     Localhost VNC display (default: 1, TCP port 5901)
  --help              Show this help

This helper only boots the installer. Power the VM off after installation;
do not boot the installed Unraid OS inside this temporary guest.
EOF
}

while (($#)); do
    case "$1" in
        --iso)
            [[ $# -ge 2 ]] || { echo "Missing value for --iso" >&2; exit 2; }
            ISO="$2"
            shift 2
            ;;
        --release-tag)
            [[ $# -ge 2 ]] || { echo "Missing value for --release-tag" >&2; exit 2; }
            RELEASE_TAG="$2"
            shift 2
            ;;
        --disk)
            [[ $# -ge 2 ]] || { echo "Missing value for --disk" >&2; exit 2; }
            DISKS+=("$2")
            shift 2
            ;;
        --state-dir)
            [[ $# -ge 2 ]] || { echo "Missing value for --state-dir" >&2; exit 2; }
            STATE_DIR="$2"
            shift 2
            ;;
        --ram)
            [[ $# -ge 2 ]] || { echo "Missing value for --ram" >&2; exit 2; }
            RAM_MIB="$2"
            shift 2
            ;;
        --cpus)
            [[ $# -ge 2 ]] || { echo "Missing value for --cpus" >&2; exit 2; }
            VCPUS="$2"
            shift 2
            ;;
        --vnc-display)
            [[ $# -ge 2 ]] || { echo "Missing value for --vnc-display" >&2; exit 2; }
            VNC_DISPLAY="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ $(id -u) -eq 0 ]] || { echo "Run this helper as root in a Linux Rescue environment." >&2; exit 1; }
if [[ -n "$ISO" && -n "$RELEASE_TAG" ]]; then
    echo "Use either --iso or --release-tag, not both." >&2
    exit 2
fi
[[ ${#DISKS[@]} -le 2 ]] || {
    echo "Provide no more than two --disk arguments." >&2
    exit 1
}
if [[ ! "$RAM_MIB" =~ ^[0-9]+$ ]] || (( RAM_MIB < 2048 )); then
    echo "--ram must be an integer of at least 2048 MiB." >&2
    exit 1
fi
if [[ ! "$VCPUS" =~ ^[0-9]+$ ]] || (( VCPUS < 1 )); then
    echo "--cpus must be a positive integer." >&2
    exit 1
fi
[[ "$VNC_DISPLAY" =~ ^[0-9]+$ ]] || {
    echo "--vnc-display must be a non-negative integer." >&2
    exit 1
}

download_file() {
    local url="$1" destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --retry 3 --connect-timeout 15 \
            --output "$destination" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --timeout=15 --output-document="$destination" "$url"
    else
        echo "curl or wget is required to download the installer." >&2
        return 1
    fi
}

file_sha256() {
    sha256sum "$1" | awk '{print tolower($1)}'
}

resolve_iso() {
    local tag version asset base_url checksum_url checksum_file expected actual partial

    if [[ -n "$ISO" ]]; then
        [[ -f "$ISO" && -r "$ISO" ]] || {
            echo "Installer ISO is not readable: $ISO" >&2
            return 1
        }
        ISO="$(readlink -f "$ISO")"
        return 0
    fi

    tag="$RELEASE_TAG"
    if [[ -z "$tag" && -n "$PUBLISHED_RELEASE_TAG" ]]; then
        tag="$PUBLISHED_RELEASE_TAG"
    fi
    if [[ ! "$tag" =~ ^Installer-[[:alnum:]._-]+$ ]]; then
        echo "This development launcher is not pinned to a release." >&2
        echo "Pass --release-tag Installer-<version> or provide --iso PATH." >&2
        return 1
    fi

    command -v sha256sum >/dev/null 2>&1 || {
        echo "sha256sum is required to verify the installer download." >&2
        return 1
    }

    version="${tag#Installer-}"
    asset="unraid-installer-${version}-online.iso"
    base_url="https://github.com/${RELEASE_REPOSITORY}/releases/download/${tag}"
    checksum_url="${base_url}/${asset}.sha256"
    ISO="${STATE_DIR}/${asset}"
    checksum_file="${ISO}.sha256.download"
    partial="${ISO}.part"

    mkdir -p "$STATE_DIR"
    rm -f "$checksum_file" "$partial"
    echo "Downloading checksum for ${tag}..."
    download_file "$checksum_url" "$checksum_file"
    expected="$(awk 'NR == 1 {print tolower($1)}' "$checksum_file")"
    rm -f "$checksum_file"
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Release checksum is invalid: $checksum_url" >&2
        return 1
    fi

    if [[ -s "$ISO" ]]; then
        actual="$(file_sha256 "$ISO")"
        if [[ "$actual" == "$expected" ]]; then
            echo "Using verified cached installer: $ISO"
            return 0
        fi
        echo "Cached installer checksum does not match; downloading it again."
    fi

    echo "Downloading ${asset}..."
    download_file "${base_url}/${asset}" "$partial"
    actual="$(file_sha256 "$partial")"
    if [[ "$actual" != "$expected" ]]; then
        rm -f "$partial"
        echo "Installer checksum verification failed." >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        return 1
    fi
    mv "$partial" "$ISO"
    echo "Verified installer SHA256: $actual"
}

find_qemu_binary() {
    local candidate
    if [[ -n "$QEMU_BIN" ]]; then
        command -v "$QEMU_BIN" 2>/dev/null || return 1
        return 0
    fi
    for candidate in qemu-system-x86_64 qemu-kvm; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    return 1
}

QEMU_BIN="$(find_qemu_binary || true)"
[[ -n "$QEMU_BIN" ]] || {
    echo "qemu-system-x86_64 or qemu-kvm is required." >&2
    exit 1
}
command -v udevadm >/dev/null 2>&1 || { echo "udevadm is required." >&2; exit 1; }
[[ -c /dev/kvm ]] || { echo "/dev/kvm is unavailable; enable virtualization support first." >&2; exit 1; }

find_ovmf_pair() {
    local code vars
    while IFS='|' read -r code vars; do
        if [[ -r "$code" && -r "$vars" ]]; then
            printf '%s|%s\n' "$code" "$vars"
            return 0
        fi
    done <<'EOF'
/usr/share/OVMF/OVMF_CODE_4M.fd|/usr/share/OVMF/OVMF_VARS_4M.fd
/usr/share/OVMF/OVMF_CODE.fd|/usr/share/OVMF/OVMF_VARS.fd
/usr/share/edk2/ovmf/OVMF_CODE.fd|/usr/share/edk2/ovmf/OVMF_VARS.fd
/usr/share/edk2/x64/OVMF_CODE.4m.fd|/usr/share/edk2/x64/OVMF_VARS.4m.fd
/usr/share/edk2/x64/OVMF_CODE.fd|/usr/share/edk2/x64/OVMF_VARS.fd
/usr/share/qemu/OVMF_CODE.fd|/usr/share/qemu/OVMF_VARS.fd
/usr/share/qemu/ovmf-x64/OVMF_CODE-pure-efi.fd|/usr/share/qemu/ovmf-x64/OVMF_VARS-pure-efi.fd
EOF
    return 1
}

sanitize_id() {
    printf '%s\n' "$1" | sed -E 's/[[:space:]]+/_/g; s/[^[:alnum:]_.-]/_/g; s/^_+//; s/_+$//'
}

host_disk_id() {
    local disk="$1" model serial id
    model="$(udevadm info --query=property --name="$disk" | awk -F= '/^ID_MODEL=/{print $2; exit}')"
    serial="$(udevadm info --query=property --name="$disk" | awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}')"
    id="$(sanitize_id "${model}_${serial}")"
    [[ -n "$model" && -n "$serial" && -n "$id" ]] || return 1
    printf '%s\n' "$id"
}

short_serial() {
    udevadm info --query=property --name="$1" | awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}'
}

assert_disk_idle() {
    local disk="$1" node node_real node_name holder_dir swap_device pool_device
    local -a nodes holders

    mapfile -t nodes < <(lsblk -nrpo NAME "$disk")
    ((${#nodes[@]} > 0)) || {
        echo "Could not enumerate target disk: $disk" >&2
        return 1
    }

    for node in "${nodes[@]}"; do
        if lsblk -nrpo MOUNTPOINTS "$node" | grep -qv '^$'; then
            echo "A target disk or partition is mounted: $node" >&2
            return 1
        fi

        while read -r swap_device _; do
            [[ "$swap_device" == Filename ]] && continue
            if [[ "$(readlink -f "$swap_device")" == "$(readlink -f "$node")" ]]; then
                echo "A target disk or partition is active swap: $node" >&2
                return 1
            fi
        done < /proc/swaps

        node_real="$(readlink -f "$node")"
        node_name="${node_real##*/}"
        holder_dir="/sys/class/block/$node_name/holders"
        holders=()
        if [[ -d "$holder_dir" ]]; then
            shopt -s nullglob
            holders=("$holder_dir"/*)
            shopt -u nullglob
        fi
        if ((${#holders[@]} > 0)); then
            printf 'A target disk or partition has active block holders: %s (' "$node" >&2
            printf '%s ' "${holders[@]##*/}" >&2
            echo ')' >&2
            return 1
        fi
    done

    if command -v zpool >/dev/null 2>&1; then
        while read -r pool_device; do
            [[ "$pool_device" == /dev/* ]] || continue
            pool_device="$(readlink -f "$pool_device")"
            for node in "${nodes[@]}"; do
                if [[ "$pool_device" == "$(readlink -f "$node")" ]]; then
                    echo "A target disk or partition belongs to an active ZFS pool: $node" >&2
                    return 1
                fi
            done
        done < <(zpool status -P 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^\/dev\//) print $i}')
    fi
}

choose_disks_interactively() {
    local candidate answer selection index details
    local -a candidates selected

    [[ -t 0 && -t 1 ]] || {
        echo "No --disk arguments were provided and no interactive terminal is available." >&2
        echo "Run this launcher from a terminal or pass one or two --disk DEVICE arguments." >&2
        return 1
    }

    candidates=()
    while read -r candidate; do
        if assert_disk_idle "$candidate" >/dev/null 2>&1; then
            candidates+=("$candidate")
        fi
    done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}')

    ((${#candidates[@]} > 0)) || {
        echo "No idle whole disks are available for installer passthrough." >&2
        return 1
    }

    echo "Idle whole disks available to the installer:"
    for index in "${!candidates[@]}"; do
        details="$(lsblk -dn -o SIZE,MODEL,SERIAL "${candidates[$index]}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
        printf '  [%d] %s  %s\n' "$((index + 1))" "${candidates[$index]}" "$details"
    done
    echo ""

    if ((${#candidates[@]} <= 2)); then
        printf 'Pass %s to the installer VM? [y/N] ' \
            "$(IFS=', '; echo "${candidates[*]}")"
        read -r answer
        [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || {
            echo "Disk selection cancelled."
            return 1
        }
        DISKS=("${candidates[@]}")
        return 0
    fi

    printf 'Select one or two disk numbers separated by a space: '
    read -r -a selected
    [[ ${#selected[@]} -ge 1 && ${#selected[@]} -le 2 ]] || {
        echo "Select one or two disks." >&2
        return 1
    }
    DISKS=()
    for selection in "${selected[@]}"; do
        [[ "$selection" =~ ^[0-9]+$ ]] || {
            echo "Invalid disk number: $selection" >&2
            return 1
        }
        index=$((selection - 1))
        ((index >= 0 && index < ${#candidates[@]})) || {
            echo "Disk number is out of range: $selection" >&2
            return 1
        }
        DISKS+=("${candidates[$index]}")
    done
}

ovmf_pair="$(find_ovmf_pair || true)"
[[ -n "$ovmf_pair" ]] || {
    echo "Could not find a matching OVMF CODE/VARS pair." >&2
    exit 1
}
OVMF_CODE="${ovmf_pair%%|*}"
OVMF_VARS_TEMPLATE="${ovmf_pair#*|}"

if ((${#DISKS[@]} == 0)); then
    choose_disks_interactively
fi
[[ ${#DISKS[@]} -ge 1 && ${#DISKS[@]} -le 2 ]] || {
    echo "Select one or two physical disks." >&2
    exit 1
}

REAL_DISKS=()
HOST_IDS=()
SHORT_SERIALS=()
for disk in "${DISKS[@]}"; do
    disk_serial=""
    disk="$(readlink -f "$disk")"
    [[ -b "$disk" ]] || { echo "Not a block device: $disk" >&2; exit 1; }
    [[ "$(lsblk -dn -o TYPE "$disk")" == "disk" ]] || {
        echo "Pass a whole disk, not a partition: $disk" >&2
        exit 1
    }
    assert_disk_idle "$disk"
    disk_serial="$(short_serial "$disk")"
    if [[ ! "$disk_serial" =~ ^[[:alnum:]_.-]+$ ]]; then
        echo "Unsupported disk serial for QEMU handoff: $disk_serial" >&2
        exit 1
    fi
    REAL_DISKS+=("$disk")
    HOST_IDS+=("$(host_disk_id "$disk")")
    SHORT_SERIALS+=("$disk_serial")
done

if [[ ${#REAL_DISKS[@]} -eq 2 && "${REAL_DISKS[0]}" == "${REAL_DISKS[1]}" ]]; then
    echo "The two target disks must be different." >&2
    exit 1
fi
if [[ ${#HOST_IDS[@]} -eq 2 && "${HOST_IDS[0]}" == "${HOST_IDS[1]}" ]]; then
    echo "The two target disks resolved to the same persistent ID." >&2
    exit 1
fi

mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/qemu.pid"
if [[ -s "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "A VM recorded in $PID_FILE is already running." >&2
    exit 1
fi

resolve_iso

OVMF_VARS="$STATE_DIR/OVMF_VARS.fd"
MONITOR_SOCKET="$STATE_DIR/monitor.sock"
SERIAL_LOG="$STATE_DIR/serial.log"
COMMAND_FILE="$STATE_DIR/installer-command.txt"
IDENTITY_MAP="$STATE_DIR/disk-identities.tsv"
rm -f "$MONITOR_SOCKET" "$SERIAL_LOG" "$PID_FILE"
cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"

for disk in "${REAL_DISKS[@]}"; do
    blockdev --flushbufs "$disk"
done

{
    printf '/bin/bash /boot/install/create_internal_boot.sh --ui gui --size 16384'
    printf ' --disk-id %q' "${HOST_IDS[0]}"
    if [[ ${#HOST_IDS[@]} -eq 2 ]]; then
        printf ' --disk-id-2 %q' "${HOST_IDS[1]}"
    fi
    for index in "${!REAL_DISKS[@]}"; do
        printf ' /dev/nvme%sn1' "$index"
    done
    printf '\n'
} > "$COMMAND_FILE"

: > "$IDENTITY_MAP"
for index in "${!REAL_DISKS[@]}"; do
    printf '%s\t%s\n' "${SHORT_SERIALS[$index]}" "${HOST_IDS[$index]}" >> "$IDENTITY_MAP"
done

QEMU_ARGS=(
    -name unraid-linux-rescue-installer
    -enable-kvm
    -machine "q35,accel=kvm"
    -cpu host
    -m "$RAM_MIB"
    -smp "$VCPUS"
    -rtc "base=utc"
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$OVMF_VARS"
    -drive "file=$ISO,media=cdrom,format=raw,readonly=on"
    -boot "once=d,menu=on"
    -no-reboot
    -netdev "user,id=net0"
    -device "e1000,netdev=net0"
    -fw_cfg "name=opt/unraid/physical-disk-map,file=$IDENTITY_MAP"
    -vga none
    -device virtio-vga
    -display none
    -vnc "127.0.0.1:$VNC_DISPLAY"
    -monitor "unix:$MONITOR_SOCKET,server=on,wait=off"
    -serial "file:$SERIAL_LOG"
    -parallel none
    -pidfile "$PID_FILE"
    -daemonize
)

for index in "${!REAL_DISKS[@]}"; do
    pci_address=$((3 + index))
    QEMU_ARGS+=(
        -drive "file=${REAL_DISKS[$index]},format=raw,if=none,id=disk$index,cache=none,aio=native"
        -device "nvme,drive=disk$index,serial=${SHORT_SERIALS[$index]},bus=pcie.0,addr=$pci_address"
    )
done

"$QEMU_BIN" "${QEMU_ARGS[@]}"

vnc_port=$((5900 + VNC_DISPLAY))
echo "Installer VM started (PID $(cat "$PID_FILE"))."
echo "VNC listens only on Rescue localhost port $vnc_port."
echo "Forward it from your computer with:"
echo "  ssh -L ${vnc_port}:127.0.0.1:${vnc_port} root@<server-ip>"
echo ""
echo "Inside the installer, open Shell, verify guest serials with:"
echo "  lsblk -d -o NAME,SIZE,MODEL,SERIAL"
echo "The installer will read physical IDs automatically from QEMU fw_cfg."
echo "If automatic discovery fails, run the fallback command saved at: $COMMAND_FILE"
cat "$COMMAND_FILE"
echo ""
echo "Power off the VM after installation. Do not boot installed Unraid in this VM."
