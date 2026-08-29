# Install on Hetzner from Linux Rescue

Use this workflow when Hetzner virtual media cannot boot the Unraid Installer
reliably. Linux Rescue remains the host while the official installer ISO runs
inside a temporary KVM/QEMU guest. The guest writes directly to the server's
physical disks. The completed Unraid system then boots on bare metal.

Do not run the internal-install script directly in stock Rescue. Rescue does
not provide the same `ungrub`, ZFS, and installer runtime as the official ISO.

This process erases the selected disks. Keep Rescue SSH available until the
bare-metal boot is verified.

## Why the VM needs physical disk identities

QEMU exposes a passed-through NVMe device with a virtual model such as
`QEMU_NVMe_Ctrl`. Bare-metal Unraid sees the physical model instead. The
serial can match while the complete Unraid disk identity differs:

```text
QEMU_NVMe_Ctrl_<serial>
SAMSUNG_MZVL21T0HCLR-00B00_<serial>
```

Saving the virtual identity makes the WebGUI report the p4 data-partition
slot as missing after physical boot. The Rescue helper records the host IDs
before starting QEMU and passes the serial-to-ID mapping through QEMU
`fw_cfg`. The installer kernel exposes that data through sysfs and the
installer reads it automatically.

## 1. Start Hetzner Linux Rescue

Activate Linux Rescue in Hetzner Robot with your SSH key and reboot the
server. Confirm the Rescue SSH host key before signing in.

Install QEMU, OVMF, and a VNC client or noVNC. Package names vary by Rescue
image. The helper needs:

- `qemu-system-x86_64`;
- `/dev/kvm`;
- a matching OVMF `CODE` and `VARS` firmware pair;
- `udevadm`, `lsblk`, and `blockdev`; and
- the official Unraid Installer ISO on the Rescue filesystem.

Keep VNC and noVNC bound to localhost and reach them through SSH. Never expose
either service on the public interface.

## 2. Identify the physical disks

Use stable `/dev/disk/by-id` paths rather than kernel names:

```bash
ls -l /dev/disk/by-id/nvme-*
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
```

Linux can swap `nvme0n1` and `nvme1n1` across reboots. Match disks by model
and serial, and confirm that no target disk or partition is mounted.

## 3. Start the official installer in QEMU

Clone or copy this repository into Rescue, then run:

```bash
sudo ./scripts/hetzner-rescue-vm.sh \
  --iso /root/unraid-installer-online.iso \
  --disk /dev/disk/by-id/nvme-<first-physical-id> \
  --disk /dev/disk/by-id/nvme-<second-physical-id>
```

The helper:

- refuses partitions and mounted target disks;
- records each host-visible model and serial;
- starts a UEFI KVM guest with NAT networking;
- passes one or two physical whole disks through as NVMe devices;
- uses stable guest PCI addresses so disk argument order is predictable;
- passes the physical identity map through QEMU `fw_cfg` without adding a
  guest block device;
- binds VNC to Rescue localhost only; and
- writes a fallback installer command to
  `/root/unraid-installer-vm/installer-command.txt`.

The default VNC display is `:1`, which uses TCP port 5901. Forward it from
your computer:

```bash
ssh -L 5901:127.0.0.1:5901 root@<server-ip>
```

Connect a local VNC client to `127.0.0.1:5901`. If you use noVNC, bind its
websocket listener to Rescue localhost and forward that port instead.

## 4. Run Simon's internal installer

In the installer menu, download or select the intended Unraid ZIP. You can
open **Shell** and verify the guest mapping:

```bash
lsblk -d -o NAME,SIZE,MODEL,SERIAL
```

Return to the menu and select **Create Internal Boot** normally. The installer
reads the `fw_cfg` map, matches each selected guest disk by short serial, and
writes the corresponding physical ID.

If handoff discovery fails, stop rather than completing the install with QEMU
IDs. The Rescue helper also writes a fallback command to
`installer-command.txt`; it has this shape:

```bash
/bin/bash /boot/install/create_internal_boot.sh \
  --ui gui \
  --size 16384 \
  --disk-id '<first-host-id>' \
  --disk-id-2 '<second-host-id>' \
  /dev/nvme0n1 /dev/nvme1n1
```

When using the fallback, each host ID must correspond to the guest disk
argument in the same position. The installer writes the physical IDs to
`config/pools/<pool>.cfg` with `diskIdSlot="-"`.

For a mirror, the installer also reads both `BOOTX64.EFI` files directly from
the raw FAT partitions. If they differ, it copies the loader produced by the
second `mkbootable add` to the first ESP, reads it back, and verifies the two
loaders byte for byte.

## 5. Stop the VM before booting Unraid

After **Internal boot image creation complete**, review the operation log and
power off the installer VM. Wait for QEMU to exit, then flush the host disks:

```bash
blockdev --flushbufs /dev/disk/by-id/nvme-<first-physical-id>
blockdev --flushbufs /dev/disk/by-id/nvme-<second-physical-id>
sync
```

Do not boot the installed Unraid OS inside the temporary VM. A full Unraid
boot can rewrite pool assignments using QEMU identities and make the physical
p4 data-partition slots appear missing.

## 6. Verify the ESPs from Rescue

The installer already verifies the mirrored EFI loaders. For an independent
pre-boot check, use `mtools` without mounting either FAT filesystem:

```bash
mkdir -p /tmp/unraid-efi-check
mcopy -o -i /dev/nvme0n1p2 ::/EFI/BOOT/BOOTX64.EFI \
  /tmp/unraid-efi-check/disk0-BOOTX64.EFI
mcopy -o -i /dev/nvme1n1p2 ::/EFI/BOOT/BOOTX64.EFI \
  /tmp/unraid-efi-check/disk1-BOOTX64.EFI
sha256sum /tmp/unraid-efi-check/*-BOOTX64.EFI
cmp /tmp/unraid-efi-check/disk0-BOOTX64.EFI \
  /tmp/unraid-efi-check/disk1-BOOTX64.EFI
```

Resolve the current partition paths from the stable disk IDs before running
those commands. The hashes must match and `cmp` must produce no output.

Also verify that the ZFS `flash` pool imports with every expected member, then
export it cleanly. Check UEFI entries with `efibootmgr -v` and set a one-time
physical boot entry with `efibootmgr -n <boot-number>` when needed.

## 7. Validate the bare-metal boot

After rebooting out of Rescue, verify:

- the expected Unraid version is running;
- `zpool status flash` reports every member online with no errors;
- `/dev/tpm0` exists when the server has TPM 2.0;
- `/var/local/emhttp/disks.ini` contains physical IDs and no QEMU IDs;
- each configured p4 data-partition slot is `DISK_OK`; and
- SSH and the management UI are reachable only through the intended network
  paths.

An unformatted p4 data partition can show a recovery or format-required pool
state while its device identity is correct. Do not format it unless creating
that data pool is intended.
