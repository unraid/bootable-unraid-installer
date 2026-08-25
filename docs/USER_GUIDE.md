# Unraid Installer User Guide

Use Unraid Installer to boot a target machine and prepare a device for an
Unraid installation. It can create an Unraid flash boot device or an internal
boot device directly on the target machine.

This guide explains when to use Unraid Installer, which release asset to
choose, and how to complete the installation.

## Choose the right tool

Choose the tool that matches where you are working:

| Tool | Use it when | Where it runs |
| --- | --- | --- |
| Flash Creator | You are on a laptop or desktop and want to create an Unraid USB flash drive. | Your laptop or desktop |
| Unraid Installer | You are working on the target machine, need internal boot, or are installing in Proxmox, Hetzner, or another remote or virtualized environment. | The target machine |

Flash Creator does not require a display on the server while it creates the
USB drive. Unraid Installer requires display or console access to the target
machine because you must boot the installer and use its menu there.

## What Unraid Installer can do

Unraid Installer provides these functions:

- Download an Unraid OS ZIP release to the installer media.
- Create a USB flash boot device with a FAT32 `UNRAID` partition.
- Create an internal boot device on one disk.
- Create a mirrored internal boot device on two disks.
- Select the size of the internal boot pool.
- Configure a network connection with DHCP and show network status.
- Connect to Wi-Fi when the image contains the required tools and detects a
  wireless interface.
- Resize the installer persistence area when the image supports it.
- Open a shell for advanced troubleshooting.

## Before you start

Prepare the following items:

1. A target machine with display or console access.
2. An installer image from the [latest stable GitHub release][releases].
3. A USB drive if you will boot the installer from USB, or virtual media if
   you will boot an ISO through a remote console or virtual machine.
4. A target disk that you are willing to erase.
5. Network access if you use the online installer or need to download an OS
   ZIP from the installer menu.

Back up any data that you need before you select a target disk. The **Create
Flash Boot** and **Create Internal Boot** actions erase the selected target
disk or disks. The installer asks for confirmation before it performs this
operation.

Do not select the device that is running the installer as the internal boot
target. The installer checks for this case and refuses to overwrite the active
installer device.

## Choose an installer release asset

The release page provides different assets for different boot paths:

| Asset | Use it when | Network requirement during installation |
| --- | --- | --- |
| `unraid-installer-<version>-online.iso` | You will boot from an ISO through virtual media or a remote console. | The target must reach the release service when it downloads the OS ZIP. |
| `unraid-installer-<version>-online.img.zip` | You will write an installer image to a USB drive. Extract the ZIP before you write the IMG file. | The target must reach the release service when it downloads the OS ZIP. |
| `unraid-installer-<version>-bundled.img.zip` | You want the approved OS payload on the installer media already. Extract the ZIP before you write the IMG file. | The OS payload is already on the installer media. |

Use the online installer for a smaller download when the target has network
access. Use the bundled installer when the installer media should already
contain the OS payload.

The release page also provides checksum files for the downloadable assets. Use
them when your download or imaging tool supports checksum verification.

## Boot the installer

1. Download the asset that matches your boot path from the [latest stable
   release][releases].
2. If you downloaded an IMG ZIP, extract it.
3. Start the target machine from the installer:
   - For an ISO, attach the ISO through virtual media or a virtual machine
     console.
   - For an IMG, write the image to a USB drive with a disk imaging tool such
     as Rufus or Balena Etcher. Select the whole USB device, not a partition.
4. Select the installer device in the target machine boot menu.
5. Wait for the **Unraid ISO Installer** menu.

Writing an installer IMG to a USB drive erases that USB drive. Verify the
selected device before you start the write operation.

## Use the installer menu

The main menu provides these actions:

| Menu action | Purpose |
| --- | --- |
| **Download ZIP** | Download an Unraid OS ZIP and save it for the boot actions. The online installer needs network access for this step. |
| **Set Internal Boot Size** | Set the boot pool size before you create an internal boot device. The menu provides dedicated, 8 GiB, 16 GiB, 32 GiB, and custom choices. |
| **Create Internal Boot** | Prepare one or two internal disks for Unraid boot. Two disks create a mirrored boot device set. |
| **Create Flash Boot** | Prepare one USB disk as an Unraid flash boot device. |
| **Show Network Status** | Display interfaces, IP addresses, and routes. |
| **Retry Network (DHCP)** | Bring up network interfaces and retry DHCP. |
| **Connect Wi-Fi + DHCP** | Connect a detected wireless interface when Wi-Fi support is available in the image. |
| **Shell** | Open a shell for advanced troubleshooting. |
| **Resize Persistence** | Resize the persistence area when the image provides the resize utility. |
| **Power Off** and **Reboot** | Shut down or restart the target machine. |

If the image does not have a graphical menu backend, the installer uses a text
prompt instead.

## Create a flash boot device

Use this path when the target machine will boot Unraid from a USB flash drive.

1. Select **Download ZIP** and select an Unraid release. Skip this step when a
   bundled image already contains the required ZIP.
2. Select **Create Flash Boot**.
3. Select the target USB disk. Select the whole disk, not a partition.
4. Read the warning and confirm that the disk can be erased.
5. Wait for the installer to create one FAT32 partition labeled `UNRAID`, copy
   the Unraid files, and make the device bootable.
6. When the operation completes, reboot the target and select the new flash
   boot device.

The selected USB disk is erased. Do not select the USB device that contains the
running installer unless you have already booted the installer from another
device.

## Create an internal boot device

Use this path when the target machine should boot Unraid from internal storage.
This path is useful for direct server installs and for remote or virtualized
environments where a permanent internal boot device is preferred.

1. Select **Download ZIP** and select an Unraid release. Skip this step when a
   bundled image already contains the required ZIP.
2. Select **Set Internal Boot Size** if the default size is not suitable.
3. Select **Create Internal Boot**.
4. Select one disk or two disks. Select two disks to create a mirrored boot
   device set.
5. Select the boot pool size. Use **Dedicated** to use the disk as a dedicated
   boot device, or select a fixed or custom size.
6. Enter a boot pool name. The name must start with a lowercase letter and can
   contain lowercase letters, numbers, `-`, and `_`.
7. Verify the selected disk or disks and confirm the destructive action.
8. Wait while the installer creates the partition layout, copies the Unraid
   files, validates the SHA256 files, and writes the boot configuration.
9. When the operation completes, reboot the target and select the new internal
   boot device.

The internal boot action erases every selected disk. The installer also checks
that the selected disk is not the active installer device or the disk that
contains the running root filesystem.

## Troubleshooting

### The installer says that a ZIP is required

Select **Download ZIP** first. If the download fails, select **Show Network
Status** and then **Retry Network (DHCP)**. For a target without network access,
boot a bundled installer image.

### The installer cannot find a release

Check the network status and confirm that the target has a usable IP address and
default route. Retry the network setup, then run **Download ZIP** again.

### The target disk is not listed

Confirm that the disk is connected and passed through to the target machine.
Select the whole disk, such as `/dev/sdb` or `/dev/nvme1n1`, rather than a
partition such as `/dev/sdb1`.

### The installer refuses to use a disk

The installer refuses to overwrite the device that is running the installer or
the active root disk. Boot the installer from a different device and select the
intended target disk.

### A checksum validation fails

Stop the operation. Check the target media and the downloaded ZIP. Download the
release again or use a different installer device before you try again.

## After the boot device is ready

Reboot the target and select the new flash or internal boot device in the
firmware or virtual machine boot settings. Continue with the normal Unraid
setup after Unraid starts.

## Related links

- [Latest Unraid Installer release][releases]
- [Unraid Installer repository][repository]
- [Stable installer download endpoint][endpoint]

[endpoint]: https://releases.unraid.net/unraid-installer
[releases]: https://github.com/unraid/bootable-unraid-installer/releases/latest
[repository]: https://github.com/unraid/bootable-unraid-installer
