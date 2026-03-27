# mira

This is forked project from the original [nabakdev/S905X-ArchLinuxARM](https://github.com/nabakdev/S905X-ArchLinuxARM/) for making the ALARM (Arch Linux ARM) for FiberHome HG680P and ZTE B860H (the most cheapest STBs you got and popular in some countries). The name of this forked project is inspired by an VTuber named [Mira Fridayanti](https://virtualyoutuber.fandom.com/id/wiki/Mira_Fridayanti) which she made me inspired to bring me back into VTubing (yeah, I am also VTuber) and I am also want to make the implementation into Go language for this project (coming soon, for now I want to improve something here for my own experiment before I implement into Go language).

---

## Supported Targets

| Device | SoC | Architecture |
|---|---|---|
| FiberHome HG680P | Amlogic S905X | AArch64 |
| ZTE B860H | Amlogic S905X | AArch64 |

The produced image runs **Arch Linux ARM (aarch64)** with a boot chain based on a MainLine U-Boot stub loaded from the SD card or eMMC FAT32 partition.

---

## Disk Layout

The image uses a modern GPT partition table with full UEFI support (via GRUB) with the following layout:

| # | Name | Label | Offset | Size | Filesystem | Flags |
|---|---|---|---|---|---|---|
| — | (reserved) | — | 0 MiB | 68 MiB | raw / bootloader | — |
| 1 | `ESP` | `BOOT` | 68 MiB | 256 MiB | FAT32 | `esp` |
| 2 | `ROOT` | `ROOT` | 324 MiB | 1536 MiB | ext4 (or btrfs) | — |

> The first 68 MiB are intentionally left raw to accommodate the vendor bootloader area expected by the Amlogic ROM.

### ext4 flags

`mkfs.ext4` is invoked with `-O ^metadata_csum,^64bit` to ensure compatibility with older U-Boot and kernel versions that ship on these devices.

---

## Boot Chain

```
Amlogic ROM
  └─► aml_autoscript   (compiled U-Boot script — triggers USB/MMC probe, reboots into s905_autoscript)
        └─► s905_autoscript  (compiled U-Boot script — loads u-boot.ext into RAM)
              └─► u-boot.ext  (MainLine U-Boot binary, executed at 0x1000000)
                  ├─► EFI/BOOT/bootaa64.efi (GRUB bootloader, modern UEFI approach)
                  │     └─► grub.cfg -> Linux kernel (Image) + DTB
                  └─► extlinux/extlinux.conf (Legacy syslinux boot menu fallback)
```

All `.cmd` source files are compiled at build time with `mkimage` into their binary counterparts. The `.cmd` sources are removed from the final image; only the compiled scripts are shipped.

---

## Repository Structure

```
mira/
├── build.sh                  # Main build script
└── src/
    ├── boot-files/
    │   ├── aml_autoscript.cmd    # AML autoscript source (U-Boot script)
    │   ├── emmc_autoscript.cmd   # eMMC autoscript source
    │   ├── s905_autoscript.cmd   # SD/USB autoscript source
    │   ├── boot.ini              # Legacy boot config
    │   ├── u-boot.ext            # MainLine U-Boot binary (executed by s905_autoscript, provides UEFI capability)
    │   └── extlinux/             # Legacy extlinux boot configuration fallback
    └── patch/
        ├── etc/
        │   ├── _bashrc           # Appended to /etc/bash.bashrc at build time
        │   ├── fstab             # Preconfigured /etc/fstab
        │   ├── profile.d/        # Drop-in shell profile scripts
        │   └── udev/             # udev rules
        └── usr/                  # Overlay applied verbatim onto the rootfs
```

---

## Build

### Prerequisites

The build script must run as **root** (it uses `losetup`, `mount`, `dd`, and `mkfs` internally). The following packages are required on the host:

| Tool | Arch Linux package | Debian/Ubuntu package |
|---|---|---|
| `parted` | `parted` | `parted` |
| `mkfs.vfat` | `dosfstools` | `dosfstools` |
| `mkfs.ext4` | `e2fsprogs` | `e2fsprogs` |
| `mkfs.btrfs` | `btrfs-progs` | `btrfs-progs` |
| `bsdtar` | `libarchive` | `libarchive-tools` |
| `mkimage` | `uboot-tools` | `u-boot-tools` |
| `xz` | `xz` | `xz-utils` |
| `losetup` | `util-linux` | `util-linux` |

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `WORKING_DIR` | `$SCRIPT_DIR/mira-workspace` | Root directory for all build artefacts |
| `ROOTFS_TARBALL_FILE` | `$WORKING_DIR/ArchLinuxARM-aarch64-latest.tar.gz` | Path to the upstream ALARM aarch64 tarball |
| `OUT_FILENAME` | `Mira-ArchLinuxARM-aarch64_S905X` | Base name (without extension) of the output image |
| `DESKTOP_ENV` | `minimal` | Desktop Environment to install (Options: `minimal`, `xfce`, `mate`, `lxde`, `cosmic`). Can be set via interactive prompt if running locally. |

### Running Locally

```bash
# 1. Clone the repository and navigate into it
git clone https://github.com/jimed-rand/mira.git
cd mira

# 2. Run the builder (Needs root privileges)
sudo bash build.sh
```

> **Note:** The script will automatically create the `mira-workspace` directory and download the Arch Linux ARM rootfs tarball if it doesn't already exist.

When run interactively without CI variables, you will be prompted to select a Desktop Environment to pre-install into the generated image.

The compressed image (`*.img.xz`) will be generated and placed in the project root directory alongside `build.sh`.

### Build Stages

| Stage | Action |
|---|---|
| 1/5 Setup IMG | `dd` allocates the raw image; `parted` writes the MBR + partitions; `mkfs` formats both partitions |
| 2/5 Mount IMG | loop device attached via `losetup -P`; partitions mounted under `./mnt` |
| 3/5 Copy files | Boot files overlaid onto `mnt/boot`; rootfs tarball extracted via `bsdtar`; patch overlay applied |
| [Optional DE] | If selected, copies `qemu-aarch64-static` to chroot into the rootfs and installs the requested Desktop Environment along with base tools |
| 4/5 Boot files | `mkimage` compiles all `.cmd` scripts; fallback initramfs and compressed kernel image removed |
| 5/5 Compress | `xz -9` compresses the image; `.img.xz` moved to the script's origin directory |

---

## First Boot

Flash the `.img.xz` image to a **USB drive** (≥ 4 GiB recommended):

```bash
xz -d Mira-ArchLinuxARM-aarch64_S905X.img.xz
sudo dd if=Mira-ArchLinuxARM-aarch64_S905X.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

> Replace `/dev/sdX` with your actual block device. **All existing data on the target device will be destroyed.**

> If you don't want to use `dd`, you can use another tool with GUI which helps you like Balena Etcher, Raspberry Pi Imager, GNOME Disks, Rufus with DD method (if you use Windows and run thsi program under WSL2), etc.

### Default Credentials

| Role | Username | Password |
|---|---|---|
| Superuser | `root` | `root` |
| Unprivileged | `alarm` | `alarm` |

### Post-boot: Initialize Pacman Keyring

The official Arch Linux ARM tarball ships without a populated keyring. Run the following **once** after the first boot:

```bash
pacman-key --init
pacman-key --populate archlinuxarm
```

---

## License

This project is distributed under the **MIT License**.

### Permissions and Conditions
Under the MIT License, you are granted extensive permissions to deal in the Software without restriction, including the rights to:
* **Use, copy, and modify** the build system and generated images.
* **Distribute, sublicense, and/or sell** copies of the integration for both personal and commercial purposes.

**Condition of Use:**
The above permissions are granted provided that the original copyright notice and permission notice are included in all copies or substantial portions of the software.

### Liability and Warranty
This software is provided **"AS IS"**, without any warranty of any kind (express or implied). The authors or copyright holders hold no liability for any claims, damages, or other liabilities arising from the use of this software.

See the [LICENSE](LICENSE) file for the full text.
