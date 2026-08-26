# Restore Existing Internal Boot process

This is the process used by **Recovery → Restore Existing Internal Boot**
(`scripts/menu_recovery_restore_existing.sh`). It preserves the existing disk
partition table and ZFS pool, and replaces files in the mounted boot dataset.

## What the script does

1. Requires `/mnt/persist` and searches `/mnt/persist/recovery-backups/*.zip`.
2. Lets the operator select a backup and copies it to a private temporary file
   under `/run` before validation.
3. Checks ZIP integrity, requires `config/` and `bzimage`, rejects path
   traversal, and rejects symbolic links.
4. Refuses to continue if the configured pool (`flash` by default) is already
   imported.
5. Imports the pool with a temporary root, mounts `${pool}/boot`, and verifies
   that its mount point is below that root.
6. Reads the target pool GUID with `zpool get ... guid` and validates that the
   backup contains a numeric `unraiduuid`.
7. Creates a ZFS rollback snapshot.
8. Deletes the mounted boot filesystem, extracts the backup ZIP, and rewrites
   its `unraiduuid` to the current target pool GUID.
9. Calls `sync`, destroys the rollback snapshot, exports the pool, and reports
   **Restore Complete**.

If extraction or a later step fails, exit cleanup attempts to roll back the
snapshot and export the pool.

## EFI handling

The script does not repartition either disk, run `mkbootable`, or update the
EFI system partitions. EFI synchronization is intentionally deferred while
the ZFS restore and pool-UUID handling are validated.

This is required because ZFS mirrors the data partition, but the EFI system
partition on each disk is independent FAT storage.

## Why it can report success but fail to boot

The success dialog means only that the ZIP was extracted and the ZFS pool was
exported. Boot can still fail when one or both EFI partitions contain an old
or missing GRUB loader/configuration, when the backup `grub/grub.cfg` cannot be
rewritten with the target pool GUID, when the backup belongs to
different pool members, or when firmware boots the EFI partition that was not
updated.

The restore-existing path rewrites the backup's GRUB `unraiduuid` to the
currently imported pool's GUID. This prevents a backup from carrying an old
pool identity into the restored boot files.

## Checks before rebooting

Review the operation log, then record the target pool identity and restored
GRUB identity from a rescue shell:

```bash
zpool get -H -o value guid flash
zpool status -g flash
grep -R -nE 'unraiduuid=|root=|boot=' /path/to/mounted/boot/grub /path/to/mounted/boot/config 2>/dev/null
```

For a mirror, manually compare and synchronize both EFI partitions before
rebooting. Treat **Restore Complete** as a verified ZFS file-level restore, not
as confirmation that firmware boot files were updated.
