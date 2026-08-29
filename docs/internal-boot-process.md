# Internal boot creation process

This document describes what `scripts/create_internal_boot_user.sh` does when
creating an internal Unraid boot pool. The script performs destructive disk
operations, so confirm the selected disks before continuing.

## Inputs

The script obtains an Unraid server ZIP from `${PERSISTENT_ROOT}/zips` (or the
`zip` compatibility directory). A restore operation can instead provide a
backup with `--restore-backup PATH`. The backup must contain `config/` and
`bzimage`, and must not contain unsafe paths or symbolic links.

The target can be one disk or two disks:

```text
create_internal_boot_user.sh [--ui text|gui] [--size SIZE_MIB] [--restore-backup PATH]
                             [--disk-id ID] [--disk-id-2 ID] [disk1] [disk2]
```

Two disks create a mirrored ZFS boot pool. The EFI system partitions are FAT
partitions and are not part of the ZFS mirror.

`--disk-id` and `--disk-id-2` override the identities written to
`config/pools/<pool>.cfg`. Use them when the installer runs in a temporary VM
whose virtual disk model differs from the physical model that Unraid will see
after reboot and no automatic identity handoff is available. The corresponding
environment variables are `INTERNAL_BOOT_DISK_ID` and
`INTERNAL_BOOT_DISK_ID_2`.

The Linux Rescue launcher instead passes a serial-to-ID map through QEMU
`fw_cfg`. The installer kernel exposes it at
`/sys/firmware/qemu_fw_cfg/by_name/opt/unraid/physical-disk-map/raw`, and the
installer maps each guest disk's short serial to its host-visible ID. Explicit
command-line overrides take precedence and remain available as a recovery
path.

## Execution phases

1. Select and validate the ZIP/backup, load the ZFS kernel module, and select
   one or two target disks.
2. Calculate the requested boot-pool size and ask for the boot-pool name.
3. Refuse to use the installer device or the running root disk as a target.
4. Ask for explicit confirmation, then wipe the partition table on every
   selected disk.
5. Run `mkbootable add` once for each selected disk. This creates the bootable
   partition layout and prepares `/boot-transfer`.
6. For a mirror, read both `BOOTX64.EFI` files directly with `mtools`. The
   second `mkbootable add` produced the loader matching the final shared GRUB
   modules, so copy it to the first ESP when the files differ and verify the
   result byte for byte.
7. Extract the ZIP (or restore backup) into `/boot-transfer`. For a restore,
   the generated `grub.cfg` Unraid UUID is retained and the backup is updated
   to use it. A normal ZIP excludes its EFI, GRUB, and installer helper files
   because those are created by `mkbootable`.
8. Validate every `*.sha256` file in the extracted payload. A mismatch aborts
   the operation before the pool is exported.
9. Write `config/pools/<pool>.cfg`, including both disk IDs and
   `diskIdSlot="-"` values for a mirror.
10. Export the `flash` pool and show the operation log.

## What “complete” means

`Internal boot image creation complete` means the commands above returned
successfully, mirrored `BOOTX64.EFI` loaders are byte-identical, and the ZFS
pool was exported. It does **not** test a firmware boot or validate the UEFI
boot order.

## Mirrored boot-pool requirement

The ZFS data partition is mirrored, but EFI is not. Each disk has its own EFI
system partition, and firmware may boot either member. The installer therefore
synchronizes and verifies the mirrored `BOOTX64.EFI` loaders after the second
`mkbootable add`. It uses `mtools` against the raw FAT partitions so it does
not create stacked mounts or verify stale page-cache data.

Also verify:

- both disks are present in `config/pools/<pool>.cfg`;
- disk IDs match what bare-metal Unraid will report, rather than temporary VM
  models;
- the ZFS pool imports cleanly and reports both members;
- the firmware boot entry/order points at the intended disk(s); and
- a cold boot is tested with each disk selected individually when the firmware
  permits it.

The operation log is retained at the path printed by the script. Review it
before rebooting, especially the `mkbootable add` and mirrored EFI verification
output. For a Linux Rescue VM workflow, follow
[Linux Rescue installation](linux-rescue-install.md).
