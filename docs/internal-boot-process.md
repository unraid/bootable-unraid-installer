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
create_internal_boot_user.sh [--ui text|gui] [--size SIZE_MIB] [--restore-backup PATH] [disk1] [disk2]
```

Two disks create a mirrored ZFS boot pool. The EFI system partitions are FAT
partitions and are not part of the ZFS mirror.

## Execution phases

1. Select and validate the ZIP/backup, load the ZFS kernel module, and select
   one or two target disks.
2. Calculate the requested boot-pool size and ask for the boot-pool name.
3. Refuse to use the installer device or the running root disk as a target.
4. Ask for explicit confirmation, then wipe the partition table on every
   selected disk.
5. Run `mkbootable add` once for each selected disk. This creates the bootable
   partition layout and prepares `/boot-transfer`.
6. Extract the ZIP (or restore backup) into `/boot-transfer`. For a restore,
   the generated `grub.cfg` Unraid UUID is retained and the backup is updated
   to use it. A normal ZIP excludes its EFI, GRUB, and installer helper files
   because those are created by `mkbootable`.
7. Validate every `*.sha256` file in the extracted payload. A mismatch aborts
   the operation before the pool is exported.
8. Write `config/pools/<pool>.cfg`, including both disk IDs for a mirror.
9. Export the `flash` pool and show the operation log.

## What “complete” means

`Internal boot image creation complete` means the commands above returned
successfully and the ZFS pool was exported. It does **not** test a firmware
boot, validate the UEFI boot order, or prove that both disks' independent EFI
partitions contain identical boot files.

## Mirrored boot-pool requirement

The ZFS data partition is mirrored, but EFI is not. Each disk has its own EFI
system partition, and firmware may boot either member. After a two-disk run,
verify both EFI partitions contain the same `EFI/BOOT` files and GRUB
configuration. If the platform or `mkbootable` version did not populate both
partitions, mount each EFI partition and copy the known-good contents to the
other member before rebooting. Do not assume that writing `/boot` or exporting
the ZFS pool updates a FAT EFI partition.

Also verify:

- both disks are present in `config/pools/<pool>.cfg`;
- the ZFS pool imports cleanly and reports both members;
- the firmware boot entry/order points at the intended disk(s); and
- a cold boot is tested with each disk selected individually when the firmware
  permits it.

The operation log is retained at the path printed by the script. Review it
before rebooting, especially the `mkbootable add` output for each disk.

