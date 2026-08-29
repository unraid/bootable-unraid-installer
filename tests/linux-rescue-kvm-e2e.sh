#!/bin/bash
# Destructive end-to-end harness for the Linux Rescue KVM installer path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/linux-rescue-vm.sh"
STATE_DIR="/root/unraid-installer-e2e"
RAM_MIB="4096"
VCPUS="4"
VNC_DISPLAY="1"
NETWORK_BRIDGE=""
ISO=""
SEED_IMAGE=""
UNRAID_ZIP=""
DISKS=()
ACTION="${1:-}"
VERIFY_POOL_IMPORTED=0
VERIFY_TEMP_DIR=""
VERIFY_MOUNT_DIRS=()
CI_NBD_DISKS=()
CI_UDEV_RULE=""
CI_TAIL_PID=""
CI_SERIAL_SOCKET=""

usage() {
    cat <<'USAGE'
Usage:
  sudo UNRAID_RESCUE_E2E_CONFIRM=ERASE_DISPOSABLE_DISKS \
    tests/linux-rescue-kvm-e2e.sh launch --iso PATH --disk DEVICE --disk DEVICE [options]
  sudo tests/linux-rescue-kvm-e2e.sh stop [--state-dir DIR]
  sudo tests/linux-rescue-kvm-e2e.sh verify [--disk DEVICE --disk DEVICE] [--state-dir DIR]
  sudo tests/linux-rescue-kvm-e2e.sh ci --iso PATH --unraid-zip PATH [options]
  sudo tests/linux-rescue-kvm-e2e.sh ci-menu --iso PATH --unraid-zip PATH [options]
  sudo tests/linux-rescue-kvm-e2e.sh ci-emmc --iso PATH --unraid-zip PATH [options]

Actions:
  launch   Start the installer VM with exactly two disposable whole disks.
  stop     Stop the test VM through its QEMU monitor, then flush both disks.
  verify   Read-only validation of partitions, the mirrored flash pool, EFI
           loaders, and persisted host-visible disk identities.
  ci       Create disposable sparse disks, run the install unattended, verify
           it, and clean up. This action is intended for ephemeral CI runners.
  ci-menu  Boot the real ISO menu in KVM, drive its text prompts through the
           serial console, verify the install, and clean up.
  ci-emmc  Install to one emulated MMC device through the real ISO menu and
           verify the eMMC product-plus-serial Boot Pool identity path.

Options:
  --iso PATH          Installer ISO to boot (required by launch)
  --disk DEVICE       Disposable whole block device; pass exactly twice
  --state-dir DIR     Harness and launcher state (default: /root/unraid-installer-e2e)
  --launcher PATH     Rescue launcher to test (default: scripts/linux-rescue-vm.sh)
  --ram MIB           Installer guest memory (default: 4096)
  --cpus COUNT        Installer guest vCPUs (default: 4)
  --vnc-display N     Localhost VNC display (default: 1)
  --bridge INTERFACE  Existing Linux bridge for hosts without user/passt networking
  --seed-image PATH   Read-only installer persistence seed passed to the launcher
  --unraid-zip PATH   Verified Unraid OS ZIP used to build the ci action seed
  --help              Show this help

This harness is destructive. Use only disks supplied by a disposable test
machine. It deliberately leaves installer-menu interaction visible through VNC.
USAGE
}

[[ -n "$ACTION" ]] || { usage >&2; exit 2; }
shift || true
if [[ "$ACTION" == "help" || "$ACTION" == "--help" || "$ACTION" == "-h" ]]; then
    usage
    exit 0
fi

while (($#)); do
    case "$1" in
        --iso)
            [[ $# -ge 2 ]] || { echo "Missing value for --iso" >&2; exit 2; }
            ISO="$2"
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
        --launcher)
            [[ $# -ge 2 ]] || { echo "Missing value for --launcher" >&2; exit 2; }
            LAUNCHER="$2"
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
        --bridge)
            [[ $# -ge 2 ]] || { echo "Missing value for --bridge" >&2; exit 2; }
            NETWORK_BRIDGE="$2"
            shift 2
            ;;
        --seed-image)
            [[ $# -ge 2 ]] || { echo "Missing value for --seed-image" >&2; exit 2; }
            SEED_IMAGE="$2"
            shift 2
            ;;
        --unraid-zip)
            [[ $# -ge 2 ]] || { echo "Missing value for --unraid-zip" >&2; exit 2; }
            UNRAID_ZIP="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$EUID" -eq 0 ]] || { echo "Run this harness as root." >&2; exit 1; }
[[ "$STATE_DIR" == /* && "$STATE_DIR" != "/" ]] || {
    echo "--state-dir must be an absolute path other than /." >&2
    exit 1
}
[[ "$RAM_MIB" =~ ^[1-9][0-9]*$ ]] || { echo "--ram must be a positive integer." >&2; exit 1; }
[[ "$VCPUS" =~ ^[1-9][0-9]*$ ]] || { echo "--cpus must be a positive integer." >&2; exit 1; }
[[ "$VNC_DISPLAY" =~ ^[0-9]+$ ]] || { echo "--vnc-display must be a non-negative integer." >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || { echo "$1 is required." >&2; exit 1; }
}

partition_path() {
    local disk="$1" number="$2"
    if [[ "$disk" =~ [0-9]$ ]]; then
        printf '%sp%s\n' "$disk" "$number"
    else
        printf '%s%s\n' "$disk" "$number"
    fi
}

normalize_disks() {
    local disk normalized
    local normalized_disks=()
    local expected_count=2

    if [[ "$ACTION" == "ci-emmc" ]]; then
        expected_count=1
    fi

    for disk in "${DISKS[@]}"; do
        normalized="$(readlink -f "$disk")"
        [[ -b "$normalized" ]] || { echo "Not a block device: $disk" >&2; exit 1; }
        [[ "$(lsblk -dn -o TYPE "$normalized")" == "disk" ]] || {
            echo "Not a whole disk: $disk" >&2
            exit 1
        }
        normalized_disks+=("$normalized")
    done
    DISKS=("${normalized_disks[@]}")

    if [[ ${#DISKS[@]} -ne "$expected_count" ]]; then
        echo "This E2E action requires exactly $expected_count test disk(s)." >&2
        exit 1
    fi
    if (( expected_count == 2 )) && [[ "${DISKS[0]}" == "${DISKS[1]}" ]]; then
        echo "The two test disks must be different." >&2
        exit 1
    fi
}

load_recorded_disks() {
    local disk_file="$STATE_DIR/e2e-host-disks"
    if [[ ${#DISKS[@]} -eq 0 && -f "$disk_file" ]]; then
        mapfile -t DISKS < "$disk_file"
    fi
    normalize_disks
}

wait_for_qemu_exit() {
    local pid="$1"
    local -i remaining=20
    while (( remaining > 0 )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 1
        remaining=$((remaining - 1))
    done
    return 1
}

launch_test() {
    local launcher_args=() disk pid

    [[ "${UNRAID_RESCUE_E2E_CONFIRM:-}" == "ERASE_DISPOSABLE_DISKS" ]] || {
        echo "Refusing destructive test without:" >&2
        echo "  UNRAID_RESCUE_E2E_CONFIRM=ERASE_DISPOSABLE_DISKS" >&2
        exit 1
    }
    [[ -n "$ISO" && -f "$ISO" ]] || { echo "launch requires --iso PATH." >&2; exit 1; }
    [[ -x "$LAUNCHER" ]] || { echo "Launcher is not executable: $LAUNCHER" >&2; exit 1; }
    require_command readlink
    require_command lsblk
    normalize_disks

    mkdir -p "$STATE_DIR"
    printf '%s\n' "${DISKS[@]}" > "$STATE_DIR/e2e-host-disks"

    launcher_args=(
        --iso "$ISO"
        --state-dir "$STATE_DIR"
        --ram "$RAM_MIB"
        --cpus "$VCPUS"
        --vnc-display "$VNC_DISPLAY"
    )
    if [[ -n "$NETWORK_BRIDGE" ]]; then
        launcher_args+=(--bridge "$NETWORK_BRIDGE")
    fi
    if [[ -n "$SEED_IMAGE" ]]; then
        launcher_args+=(--seed-image "$SEED_IMAGE")
    fi
    for disk in "${DISKS[@]}"; do
        launcher_args+=(--disk "$disk")
    done

    "$LAUNCHER" "${launcher_args[@]}"
    pid="$(cat "$STATE_DIR/qemu.pid")"
    kill -0 "$pid" 2>/dev/null || { echo "Installer VM did not remain running." >&2; exit 1; }

    cat <<EOF

Reusable Rescue E2E VM is running (PID $pid).
Complete the normal installer UI through localhost VNC display :$VNC_DISPLAY:
  1. Download or select the intended Unraid ZIP.
  2. Choose Create Internal Boot.
  3. Select Two disks (mirrored) with the cursor, then both test disks.
  4. Set the boot-pool size to 16384 MiB and complete the install.
  5. Leave the completion dialog visible; do not reboot the installed system.

Then run:
  sudo $0 stop --state-dir '$STATE_DIR'
  sudo $0 verify --state-dir '$STATE_DIR'
EOF
}

cleanup_ci() {
    local pid="" disk

    if [[ -n "$CI_TAIL_PID" ]]; then
        kill "$CI_TAIL_PID" 2>/dev/null || true
        wait "$CI_TAIL_PID" 2>/dev/null || true
    fi
    pid="$(cat "$STATE_DIR/qemu.pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        if [[ -S "$STATE_DIR/monitor.sock" ]] && command -v nc >/dev/null 2>&1; then
            printf 'quit\n' | nc -U "$STATE_DIR/monitor.sock" >/dev/null 2>&1 || true
        else
            kill -TERM "$pid" 2>/dev/null || true
        fi
        wait_for_qemu_exit "$pid" || kill -KILL "$pid" 2>/dev/null || true
    fi

    if command -v zpool >/dev/null 2>&1 && zpool list -H -o name 2>/dev/null | grep -qx flash; then
        zpool export flash 2>/dev/null || true
    fi
    for disk in "${CI_NBD_DISKS[@]}"; do
        qemu-nbd --disconnect "$disk" >/dev/null 2>&1 || true
    done
    if [[ -n "$CI_UDEV_RULE" ]]; then
        rm -f "$CI_UDEV_RULE"
        udevadm control --reload-rules 2>/dev/null || true
    fi
    if mountpoint -q "$STATE_DIR/seed-mount" 2>/dev/null; then
        umount "$STATE_DIR/seed-mount" 2>/dev/null || true
    fi
    rm -rf "$STATE_DIR/ci-storage" "$STATE_DIR/seed-mount"
    chmod a+rx "$STATE_DIR" 2>/dev/null || true
    chmod a+r "$STATE_DIR/serial.log" "$STATE_DIR/disk-identities.tsv" \
        "$STATE_DIR/installer-command.txt" 2>/dev/null || true
}

create_ci_seed() {
    local seed_root="$STATE_DIR/ci-storage/seed-root"
    local seed_runtime="$seed_root/runtime"

    SEED_IMAGE="$STATE_DIR/ci-storage/installer-seed.iso"
    mkdir -p "$seed_runtime" "$seed_root/zips"
    cp "$UNRAID_ZIP" "$seed_root/zips/"
    cat > "$seed_runtime/menu.sh" <<'EOF'
#!/bin/bash
set -uo pipefail

exec >/dev/ttyS0 2>&1
echo "UNRAID_E2E: starting unattended mirrored internal-boot installation"

if printf '\nYES\n' | \
    BOOT_POOL_NAME=boot MENU_BACKEND=text \
    /bin/bash /boot/install/create_internal_boot.sh \
        --ui text --size 16384 /dev/nvme0n1 /dev/nvme1n1; then
    echo "UNRAID_E2E_RESULT=success"
else
    result=$?
    echo "UNRAID_E2E_RESULT=failure exit=$result"
fi

sync
while true; do
    sleep 3600
done
EOF
    chmod 0755 "$seed_runtime/menu.sh"
    sync
    xorriso -as mkisofs -quiet -V INSTALL-PERSIST -o "$SEED_IMAGE" "$seed_root"
    rm -rf "$seed_root"
}

create_ci_menu_seed() {
    local seed_root="$STATE_DIR/ci-storage/seed-root"

    SEED_IMAGE="$STATE_DIR/ci-storage/installer-menu-seed.iso"
    mkdir -p "$seed_root/runtime" "$seed_root/zips"
    cp "$UNRAID_ZIP" "$seed_root/zips/"
    printf '%s\n' text > "$seed_root/runtime/menu-backend"
    sync
    xorriso -as mkisofs -quiet -V INSTALL-PERSIST -o "$SEED_IMAGE" "$seed_root"
    rm -rf "$seed_root"
}

create_ci_nbd_disk() {
    local image="$1" serial="$2" size="${3:-36G}" nbd_disk="" nbd_name candidate

    truncate -s "$size" "$image"
    for candidate in /dev/nbd*; do
        [[ "$candidate" =~ p[0-9]+$ ]] && continue
        nbd_name="${candidate##*/}"
        if [[ ! -s "/sys/class/block/$nbd_name/pid" ]]; then
            nbd_disk="$candidate"
            break
        fi
    done
    [[ -n "$nbd_disk" ]] || { echo "No unused NBD device is available." >&2; exit 1; }
    qemu-nbd --connect="$nbd_disk" --format=raw "$image"
    udevadm settle
    cat >> "$CI_UDEV_RULE" <<EOF
KERNEL=="$nbd_name", ENV{ID_MODEL}="CI_DISK", ENV{ID_SERIAL_SHORT}="$serial", ENV{ID_SERIAL}="CI_DISK_$serial"
EOF
    CI_NBD_DISKS+=("$nbd_disk")
}

refresh_ci_nbd_disks() {
    local index disk image part2 part3 part4

    for disk in "${CI_NBD_DISKS[@]}"; do
        qemu-nbd --disconnect "$disk"
    done
    for index in "${!CI_NBD_DISKS[@]}"; do
        disk="${CI_NBD_DISKS[$index]}"
        image="$STATE_DIR/ci-storage/target-$((index + 1)).raw"
        if ! qemu-nbd --connect="$disk" --format=raw "$image"; then
            echo "Unable to reopen $image on $disk for host verification." >&2
            exit 1
        fi
        echo "Reopened $image on $disk for host verification."
        part2="$(partition_path "$disk" 2)"
        part3="$(partition_path "$disk" 3)"
        part4="$(partition_path "$disk" 4)"
        for _ in {1..200}; do
            [[ -b "$part2" && -b "$part3" && -b "$part4" ]] && break
            blockdev --rereadpt "$disk" >/dev/null 2>&1 || true
            partprobe "$disk" >/dev/null 2>&1 || true
            partx --update "$disk" >/dev/null 2>&1 || partx --add "$disk" >/dev/null 2>&1 || true
            udevadm settle --timeout=2 >/dev/null 2>&1 || true
            sleep 0.1
        done
        [[ -b "$part2" && -b "$part3" && -b "$part4" ]] || {
            echo "Partition devices did not appear after reopening $disk." >&2
            lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,PARTLABEL "$disk" >&2 || true
            partx --show "$disk" >&2 || true
            exit 1
        }
    done
    udevadm settle
}

run_ci_test() {
    local pid deadline result=""

    [[ -n "$ISO" && -f "$ISO" ]] || { echo "ci requires --iso PATH." >&2; exit 1; }
    [[ -n "$UNRAID_ZIP" && -f "$UNRAID_ZIP" ]] || { echo "ci requires --unraid-zip PATH." >&2; exit 1; }
    [[ -c /dev/kvm ]] || { echo "/dev/kvm is unavailable on this runner." >&2; exit 1; }
    for command in truncate qemu-nbd modprobe udevadm partx xorriso; do
        require_command "$command"
    done

    mkdir -p "$STATE_DIR/ci-storage"
    CI_UDEV_RULE="/run/udev/rules.d/99-unraid-installer-e2e-$$.rules"
    : > "$CI_UDEV_RULE"
    trap cleanup_ci EXIT

    create_ci_seed
    modprobe nbd max_part=16
    create_ci_nbd_disk "$STATE_DIR/ci-storage/target-1.raw" E2E_PHYSICAL_01
    create_ci_nbd_disk "$STATE_DIR/ci-storage/target-2.raw" E2E_PHYSICAL_02
    udevadm control --reload-rules
    for disk in "${CI_NBD_DISKS[@]}"; do
        udevadm trigger --action=change --sysname-match="${disk##*/}"
    done
    udevadm settle
    DISKS=("${CI_NBD_DISKS[@]}")

    for disk in "${DISKS[@]}"; do
        udevadm info --query=property --name="$disk" | grep -E '^(ID_MODEL|ID_SERIAL_SHORT|ID_SERIAL)='
    done

    UNRAID_RESCUE_E2E_CONFIRM=ERASE_DISPOSABLE_DISKS launch_test
    pid="$(cat "$STATE_DIR/qemu.pid")"
    tail -n +1 -F "$STATE_DIR/serial.log" &
    CI_TAIL_PID=$!
    deadline=$((SECONDS + 1200))
    while (( SECONDS < deadline )); do
        if grep -q '^UNRAID_E2E_RESULT=success' "$STATE_DIR/serial.log"; then
            result="success"
            break
        fi
        if grep -q '^UNRAID_E2E_RESULT=failure ' "$STATE_DIR/serial.log"; then
            result="failure"
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            result="guest-exited"
            break
        fi
        sleep 2
    done
    kill "$CI_TAIL_PID" 2>/dev/null || true
    wait "$CI_TAIL_PID" 2>/dev/null || true
    CI_TAIL_PID=""
    if [[ "$result" != "success" ]]; then
        echo "The unattended installer did not report success (result: ${result:-timeout})." >&2
        tail -n 200 "$STATE_DIR/serial.log" >&2 || true
        exit 1
    fi

    stop_test
    refresh_ci_nbd_disks
    ( verify_test )
    echo "GitHub-hosted Linux Rescue KVM E2E test passed."
}

write_ci_identity_map() {
    local disk short_serial host_id
    local identity_map="$STATE_DIR/disk-identities.tsv"

    : > "$identity_map"
    for disk in "${DISKS[@]}"; do
        short_serial="$(udevadm info --query=property --name="$disk" | awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}')"
        host_id="$(udevadm info --query=property --name="$disk" | awk -F= '/^ID_SERIAL=/{print $2; exit}')"
        [[ "$short_serial" =~ ^[[:alnum:]_.-]+$ && "$host_id" =~ ^[[:alnum:]_.-]+$ ]] || {
            echo "Unable to resolve the CI identity for $disk." >&2
            exit 1
        }
        printf '%s\t%s\n' "$short_serial" "$host_id" >> "$identity_map"
    done
}

launch_ci_menu_vm() {
    local scenario="${1:-mirrored-nvme}"
    local kernel="$STATE_DIR/ci-storage/vmlinuz"
    local initrd="$STATE_DIR/ci-storage/initrd"
    local monitor_socket="$STATE_DIR/monitor.sock"
    local pid_file="$STATE_DIR/qemu.pid"
    local identity_map="$STATE_DIR/disk-identities.tsv"
    local command_file="$STATE_DIR/installer-command.txt"
    local qemu_args=()
    local index pci_address

    for command in qemu-system-x86_64 python3 xorriso; do
        require_command "$command"
    done

    xorriso -osirrox on -indev "$ISO" -extract /boot/vmlinuz "$kernel" >/dev/null 2>&1
    xorriso -osirrox on -indev "$ISO" -extract /boot/initrd "$initrd" >/dev/null 2>&1
    [[ -s "$kernel" && -s "$initrd" ]] || {
        echo "Unable to extract the installer kernel and initrd from $ISO." >&2
        exit 1
    }

    if [[ "$scenario" == "single-emmc" ]]; then
        printf '%s\n' "Real ISO menu flow: C, one emulated MMC disk, 16 GiB boot pool, boot pool name, destructive confirmation" > "$command_file"
    else
        printf '%s\n' "Real ISO menu flow: C, two NVMe disks, 16 GiB boot pool, boot pool name, destructive confirmation" > "$command_file"
        write_ci_identity_map
    fi
    printf '%s\n' "${DISKS[@]}" > "$STATE_DIR/e2e-host-disks"
    CI_SERIAL_SOCKET="$STATE_DIR/serial.sock"
    rm -f "$monitor_socket" "$CI_SERIAL_SOCKET" "$pid_file" "$STATE_DIR/serial.log"

    qemu_args=(
        -name unraid-iso-installer-menu-e2e
        -enable-kvm
        -machine "q35,accel=kvm"
        -cpu host
        -m "$RAM_MIB"
        -smp "$VCPUS"
        -rtc base=utc
        -kernel "$kernel"
        -initrd "$initrd"
        -append "root=/dev/ram0 rw rdinit=/init loglevel=3 console=ttyS0 consoleblank=0"
        -drive "file=$ISO,media=cdrom,format=raw,readonly=on"
        -display none
        -monitor "unix:$monitor_socket,server=on,wait=off"
        -serial "unix:$CI_SERIAL_SOCKET,server=on,wait=off"
        -parallel none
        -net none
        -no-reboot
        -pidfile "$pid_file"
        -daemonize
        -drive "file=$SEED_IMAGE,format=raw,if=none,readonly=on,id=installer-seed"
        -device "virtio-blk-pci,drive=installer-seed,serial=UNRAID_INSTALLER_SEED,bus=pcie.0,addr=8"
    )

    if [[ "$scenario" == "single-emmc" ]]; then
        qemu_args+=(
            -drive "file=${DISKS[0]},format=raw,if=none,id=disk0,cache=none,aio=native"
            -device "sdhci-pci,id=sdhci"
            -device "sd-card,drive=disk0"
        )
    else
        qemu_args+=(
            -fw_cfg "name=opt/unraid/physical-disk-map,file=$identity_map"
        )
        for index in "${!DISKS[@]}"; do
            pci_address=$((3 + index))
            qemu_args+=(
                -drive "file=${DISKS[$index]},format=raw,if=none,id=disk$index,cache=none,aio=native"
                -device "nvme,drive=disk$index,serial=E2E_PHYSICAL_0$((index + 1)),bus=pcie.0,addr=$pci_address"
            )
        done
    fi

    qemu-system-x86_64 "${qemu_args[@]}"
    [[ -s "$pid_file" ]] || { echo "The ISO menu VM did not create a PID file." >&2; exit 1; }
    kill -0 "$(cat "$pid_file")" 2>/dev/null || { echo "The ISO menu VM did not remain running." >&2; exit 1; }
}

run_ci_menu_test() {
    local disk

    [[ -n "$ISO" && -f "$ISO" ]] || { echo "ci-menu requires --iso PATH." >&2; exit 1; }
    [[ -n "$UNRAID_ZIP" && -f "$UNRAID_ZIP" ]] || { echo "ci-menu requires --unraid-zip PATH." >&2; exit 1; }
    [[ -c /dev/kvm ]] || { echo "/dev/kvm is unavailable on this runner." >&2; exit 1; }
    for command in truncate qemu-nbd modprobe udevadm partx xorriso python3; do
        require_command "$command"
    done

    mkdir -p "$STATE_DIR/ci-storage"
    CI_UDEV_RULE="/run/udev/rules.d/99-unraid-installer-e2e-$$.rules"
    : > "$CI_UDEV_RULE"
    trap cleanup_ci EXIT

    create_ci_menu_seed
    modprobe nbd max_part=16
    create_ci_nbd_disk "$STATE_DIR/ci-storage/target-1.raw" E2E_PHYSICAL_01
    create_ci_nbd_disk "$STATE_DIR/ci-storage/target-2.raw" E2E_PHYSICAL_02
    udevadm control --reload-rules
    for disk in "${CI_NBD_DISKS[@]}"; do
        udevadm trigger --action=change --sysname-match="${disk##*/}"
    done
    udevadm settle
    DISKS=("${CI_NBD_DISKS[@]}")

    launch_ci_menu_vm
    python3 "$SCRIPT_DIR/iso-installer-menu-driver.py" \
        --socket "$CI_SERIAL_SOCKET" \
        --transcript "$STATE_DIR/serial.log" \
        --timeout 1200

    stop_test
    refresh_ci_nbd_disks
    ( verify_test )
    echo "GitHub-hosted ISO installer menu KVM E2E test passed."
}

run_ci_emmc_test() {
    [[ -n "$ISO" && -f "$ISO" ]] || { echo "ci-emmc requires --iso PATH." >&2; exit 1; }
    [[ -n "$UNRAID_ZIP" && -f "$UNRAID_ZIP" ]] || { echo "ci-emmc requires --unraid-zip PATH." >&2; exit 1; }
    [[ -c /dev/kvm ]] || { echo "/dev/kvm is unavailable on this runner." >&2; exit 1; }
    for command in truncate qemu-nbd modprobe udevadm partx xorriso python3; do
        require_command "$command"
    done

    mkdir -p "$STATE_DIR/ci-storage"
    CI_UDEV_RULE="/run/udev/rules.d/99-unraid-installer-e2e-$$.rules"
    : > "$CI_UDEV_RULE"
    trap cleanup_ci EXIT

    create_ci_menu_seed
    modprobe nbd max_part=16
    create_ci_nbd_disk "$STATE_DIR/ci-storage/target-1.raw" E2E_EMMC_01 64G
    udevadm control --reload-rules
    udevadm trigger --action=change --sysname-match="${CI_NBD_DISKS[0]##*/}"
    udevadm settle
    DISKS=("${CI_NBD_DISKS[0]}")

    launch_ci_menu_vm single-emmc
    python3 "$SCRIPT_DIR/iso-installer-menu-driver.py" \
        --socket "$CI_SERIAL_SOCKET" \
        --transcript "$STATE_DIR/serial.log" \
        --scenario single-emmc \
        --timeout 1200

    stop_test
    refresh_ci_nbd_disks
    ( verify_emmc_test )
    echo "GitHub-hosted eMMC identity KVM E2E test passed."
}

stop_test() {
    local pid_file="$STATE_DIR/qemu.pid" pid disk

    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        if [[ -S "$STATE_DIR/monitor.sock" ]] && command -v nc >/dev/null 2>&1; then
            printf 'quit\n' | nc -U "$STATE_DIR/monitor.sock" || true
        else
            kill -TERM "$pid"
        fi
        wait_for_qemu_exit "$pid" || {
            echo "QEMU did not stop within 20 seconds." >&2
            exit 1
        }
    fi

    load_recorded_disks
    require_command blockdev
    for disk in "${DISKS[@]}"; do
        blockdev --flushbufs "$disk"
    done
    sync
    echo "Installer VM stopped and ${#DISKS[@]} test disk(s) were flushed."
}

cleanup_verify() {
    local mount_dir

    for mount_dir in "${VERIFY_MOUNT_DIRS[@]}"; do
        if mountpoint -q "$mount_dir" 2>/dev/null; then
            umount "$mount_dir" 2>/dev/null || true
        fi
    done
    VERIFY_MOUNT_DIRS=()
    if (( VERIFY_POOL_IMPORTED == 1 )); then
        zpool export flash 2>/dev/null || true
        VERIFY_POOL_IMPORTED=0
    fi
    if [[ -n "$VERIFY_TEMP_DIR" ]]; then
        rm -rf "$VERIFY_TEMP_DIR"
        VERIFY_TEMP_DIR=""
    fi
}

verify_test() {
    local disk part2 part3 part4
    local part2_paths=() part3_paths=() part4_paths=()
    local pid identity_map expected_map actual_map
    local import_root import_output status_output boot_mount pool_cfg esp0_mount esp1_mount

    for command in readlink lsblk blockdev partprobe udevadm blkid mount umount mountpoint sha256sum cmp zpool zfs awk sed sort grep find head wc xargs paste mktemp; do
        require_command "$command"
    done
    load_recorded_disks

    if [[ -s "$STATE_DIR/qemu.pid" ]]; then
        pid="$(cat "$STATE_DIR/qemu.pid")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "QEMU is still running. Stop it before verification." >&2
            exit 1
        fi
    fi

    for disk in "${DISKS[@]}"; do
        blockdev --flushbufs "$disk"
        if [[ "$ACTION" != "ci" ]]; then
            partprobe "$disk"
        fi
    done
    udevadm settle

    for disk in "${DISKS[@]}"; do
        part2="$(partition_path "$disk" 2)"
        part3="$(partition_path "$disk" 3)"
        part4="$(partition_path "$disk" 4)"
        [[ -b "$part2" && -b "$part3" && -b "$part4" ]] || {
            echo "Expected p2, p3, and p4 on $disk." >&2
            exit 1
        }
        [[ "$(blkid -s TYPE -o value "$part2")" == "vfat" ]] || {
            echo "Expected a vfat EFI partition at $part2." >&2
            exit 1
        }
        [[ "$(blkid -s TYPE -o value "$part3")" == "zfs_member" ]] || {
            echo "Expected a ZFS member at $part3." >&2
            exit 1
        }
        part2_paths+=("$part2")
        part3_paths+=("$part3")
        part4_paths+=("$part4")
    done

    [[ "$(blockdev --getsize64 "${part3_paths[0]}")" == "$(blockdev --getsize64 "${part3_paths[1]}")" ]] || {
        echo "The mirrored ZFS partitions differ in size." >&2
        exit 1
    }
    [[ "$(blockdev --getsize64 "${part4_paths[0]}")" == "$(blockdev --getsize64 "${part4_paths[1]}")" ]] || {
        echo "The data partitions differ in size." >&2
        exit 1
    }

    VERIFY_TEMP_DIR="$(mktemp -d)"
    import_root="$VERIFY_TEMP_DIR/import"
    mkdir -p "$import_root"
    trap cleanup_verify EXIT

    esp0_mount="$VERIFY_TEMP_DIR/esp0"
    esp1_mount="$VERIFY_TEMP_DIR/esp1"
    mkdir -p "$esp0_mount" "$esp1_mount"
    mount -o ro "${part2_paths[0]}" "$esp0_mount"
    VERIFY_MOUNT_DIRS+=("$esp0_mount")
    mount -o ro "${part2_paths[1]}" "$esp1_mount"
    VERIFY_MOUNT_DIRS+=("$esp1_mount")
    if ! cmp "$esp0_mount/EFI/BOOT/BOOTX64.EFI" "$esp1_mount/EFI/BOOT/BOOTX64.EFI"; then
        echo "Mirrored EFI loaders differ after reopening the CI disk images." >&2
        sha256sum "$esp0_mount/EFI/BOOT/BOOTX64.EFI" "$esp1_mount/EFI/BOOT/BOOTX64.EFI" >&2
        exit 1
    fi

    if zpool list -H -o name 2>/dev/null | grep -qx flash; then
        echo "A pool named flash is already imported; refusing ambiguous verification." >&2
        exit 1
    fi
    if ! import_output="$(zpool import -d "${part3_paths[0]}" -d "${part3_paths[1]}")"; then
        echo "Unable to inspect the installed flash pool." >&2
        exit 1
    fi
    if ! grep -Eq '^[[:space:]]+pool: flash$' <<<"$import_output"; then
        echo "The installed flash pool was not found in ZFS import output:" >&2
        printf '%s\n' "$import_output" >&2
        exit 1
    fi
    if ! grep -Eq '^[[:space:]]+mirror-0[[:space:]]+ONLINE' <<<"$import_output"; then
        echo "The installed flash pool is not an online mirror:" >&2
        printf '%s\n' "$import_output" >&2
        exit 1
    fi

    zpool import -N -o readonly=on -o cachefile=none -R "$import_root" \
        -d "${part3_paths[0]}" -d "${part3_paths[1]}" flash
    VERIFY_POOL_IMPORTED=1
    status_output="$(zpool status -P flash)"
    if ! grep -q '^ state: ONLINE$' <<<"$status_output" ||
        ! grep -q 'errors: No known data errors' <<<"$status_output" ||
        ! grep -Fq "${part3_paths[0]}" <<<"$status_output" ||
        ! grep -Fq "${part3_paths[1]}" <<<"$status_output"; then
        echo "The imported flash pool did not contain the expected healthy mirror:" >&2
        printf '%s\n' "$status_output" >&2
        exit 1
    fi

    zfs mount flash/boot
    boot_mount="$(zfs get -H -o value mountpoint flash/boot)"
    [[ "$boot_mount" == "$import_root"/* && -d "$boot_mount/config" ]] || {
        echo "Unexpected boot dataset mountpoint: $boot_mount" >&2
        exit 1
    }
    pool_cfg="$(find "$boot_mount/config/pools" -maxdepth 1 -type f -name '*.cfg' \
        -exec grep -l '^diskId' {} \; | head -n1)"
    [[ -n "$pool_cfg" ]] || { echo "No boot-pool identity file found." >&2; exit 1; }

    identity_map="$STATE_DIR/disk-identities.tsv"
    [[ -s "$identity_map" ]] || { echo "Missing identity handoff: $identity_map" >&2; exit 1; }
    expected_map="$VERIFY_TEMP_DIR/expected-ids"
    actual_map="$VERIFY_TEMP_DIR/actual-ids"
    awk -F '\t' 'NF == 2 {print $2}' "$identity_map" | sort > "$expected_map"
    sed -n 's/^diskId\(\.[0-9][0-9]*\)\?="\([^"]*\)"/\2/p' "$pool_cfg" | sort > "$actual_map"
    [[ "$(wc -l < "$expected_map" | xargs)" == "2" ]] || {
        echo "Identity handoff does not contain exactly two disks." >&2
        exit 1
    }
    if ! cmp "$expected_map" "$actual_map"; then
        echo "Persisted boot-pool identities do not match the physical-ID handoff." >&2
        echo "Expected:" >&2
        cat "$expected_map" >&2
        echo "Actual:" >&2
        cat "$actual_map" >&2
        exit 1
    fi
    if grep -R -E 'QEMU_NVMe_Ctrl_' "$boot_mount/config" >/dev/null 2>&1; then
        echo "Nested QEMU NVMe identity persisted in the installed configuration." >&2
        exit 1
    fi

    echo "Linux Rescue KVM E2E verification passed."
    echo "ZFS mirror members: ${part3_paths[0]}, ${part3_paths[1]}"
    echo "EFI loader SHA256: $(sha256sum "$esp0_mount/EFI/BOOT/BOOTX64.EFI" | awk '{print $1}')"
    echo "Persisted host IDs: $(paste -sd, "$actual_map")"
    echo "Partition layout:"
    lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,PARTLABEL,MODEL,SERIAL "${DISKS[@]}"
    cleanup_verify
    trap - EXIT
}

verify_emmc_test() {
    local disk part2 part3 part4 pid import_root import_output status_output
    local boot_mount pool_cfg actual_id observed_id esp_mount

    for command in readlink lsblk blockdev udevadm blkid mount umount mountpoint zpool zfs awk sed grep find head mktemp; do
        require_command "$command"
    done
    load_recorded_disks
    disk="${DISKS[0]}"

    if [[ -s "$STATE_DIR/qemu.pid" ]]; then
        pid="$(cat "$STATE_DIR/qemu.pid")"
        if kill -0 "$pid" 2>/dev/null; then
            echo "QEMU is still running. Stop it before verification." >&2
            exit 1
        fi
    fi

    blockdev --flushbufs "$disk"
    udevadm settle
    part2="$(partition_path "$disk" 2)"
    part3="$(partition_path "$disk" 3)"
    part4="$(partition_path "$disk" 4)"
    [[ -b "$part2" && -b "$part3" && -b "$part4" ]] || {
        echo "Expected p2, p3, and p4 on the emulated eMMC disk." >&2
        exit 1
    }
    [[ "$(blkid -s TYPE -o value "$part2")" == "vfat" ]] || {
        echo "Expected a vfat EFI partition at $part2." >&2
        exit 1
    }
    [[ "$(blkid -s TYPE -o value "$part3")" == "zfs_member" ]] || {
        echo "Expected a ZFS member at $part3." >&2
        exit 1
    }

    VERIFY_TEMP_DIR="$(mktemp -d)"
    import_root="$VERIFY_TEMP_DIR/import"
    esp_mount="$VERIFY_TEMP_DIR/esp"
    mkdir -p "$import_root" "$esp_mount"
    trap cleanup_verify EXIT

    mount -o ro "$part2" "$esp_mount"
    VERIFY_MOUNT_DIRS+=("$esp_mount")
    [[ -s "$esp_mount/EFI/BOOT/BOOTX64.EFI" ]] || {
        echo "The emulated eMMC EFI loader is missing." >&2
        exit 1
    }

    if zpool list -H -o name 2>/dev/null | grep -qx flash; then
        echo "A pool named flash is already imported; refusing ambiguous verification." >&2
        exit 1
    fi
    import_output="$(zpool import -d "$part3")"
    grep -Eq '^[[:space:]]+pool: flash$' <<<"$import_output" || {
        echo "The installed eMMC flash pool was not found:" >&2
        printf '%s\n' "$import_output" >&2
        exit 1
    }

    zpool import -N -o readonly=on -o cachefile=none -R "$import_root" -d "$part3" flash
    VERIFY_POOL_IMPORTED=1
    status_output="$(zpool status -P flash)"
    if ! grep -q '^ state: ONLINE$' <<<"$status_output" ||
        ! grep -q 'errors: No known data errors' <<<"$status_output" ||
        ! grep -Fq "$part3" <<<"$status_output"; then
        echo "The imported eMMC flash pool is not healthy:" >&2
        printf '%s\n' "$status_output" >&2
        exit 1
    fi

    zfs mount flash/boot
    boot_mount="$(zfs get -H -o value mountpoint flash/boot)"
    pool_cfg="$(find "$boot_mount/config/pools" -maxdepth 1 -type f -name '*.cfg' \
        -exec grep -l '^diskId=' {} \; | head -n1)"
    [[ -n "$pool_cfg" ]] || { echo "No eMMC boot-pool identity file found." >&2; exit 1; }
    if grep -q '^diskId\.[0-9]' "$pool_cfg"; then
        echo "The single-device eMMC pool contains an unexpected second identity." >&2
        exit 1
    fi

    actual_id="$(sed -n 's/^diskId="\([^"]*\)"/\1/p' "$pool_cfg")"
    observed_id="$(tr -d '\r' < "$STATE_DIR/serial.log" | awk '$1 == "mmcblk0" {print $NF; exit}')"
    [[ -n "$observed_id" ]] || {
        echo "The installer menu transcript did not contain the resolved mmcblk0 identity." >&2
        exit 1
    }
    [[ "$actual_id" == "$observed_id" ]] || {
        echo "The persisted eMMC identity differs from the identity shown by the installer." >&2
        echo "Installer: $observed_id" >&2
        echo "Persisted: $actual_id" >&2
        exit 1
    }
    [[ "$actual_id" == *_* && "$actual_id" != 0x* ]] || {
        echo "The persisted eMMC identity does not contain a product-name prefix: $actual_id" >&2
        exit 1
    }
    printf 'mmcblk0\t%s\n' "$actual_id" > "$STATE_DIR/disk-identities.tsv"

    echo "eMMC identity KVM E2E verification passed."
    echo "Persisted eMMC ID: $actual_id"
    echo "Partition layout:"
    lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,PARTLABEL,MODEL,SERIAL "$disk"
    cleanup_verify
    trap - EXIT
}

case "$ACTION" in
    launch) launch_test ;;
    stop) stop_test ;;
    verify) verify_test ;;
    ci) run_ci_test ;;
    ci-menu) run_ci_menu_test ;;
    ci-emmc) run_ci_emmc_test ;;
    help|--help|-h) usage ;;
    *)
        echo "Unknown action: $ACTION" >&2
        usage >&2
        exit 2
        ;;
esac
