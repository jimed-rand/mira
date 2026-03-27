#!/bin/bash

echo -e "\n============================================="
echo -e "              Mira ALARM Builder             "
echo -e "=============================================\n"

OUT_FILENAME="${OUT_FILENAME:-Mira-ArchLinuxARM-aarch64_S905X}"

ROOTFS_TYPE="ext4"

SKIP_SIZE="68"
BOOT_SIZE="256"
ROOT_SIZE="1536"
IMG_SIZE="$((SKIP_SIZE + BOOT_SIZE + ROOT_SIZE))"

BOOT_LABEL="BOOT"
ROOT_LABEL="ROOT"

IMG_FILENAME="${OUT_FILENAME}.img"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKING_DIR="${SCRIPT_DIR}/mira-workspace"
ROOTFS_URL="${ROOTFS_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
ROOTFS_TARBALL_FILE="${WORKING_DIR}/ArchLinuxARM-aarch64-latest.tar.gz"
OUT_DIR="${SCRIPT_DIR}"
BOOT_FILES="${SCRIPT_DIR}/src/boot-files"
PATCH_FILES="${SCRIPT_DIR}/src/patch"

cleanup() {
  echo -e "\n[!] Running cleanup tasks..."
  cd "${SCRIPT_DIR}" || true
  if mountpoint -q "${WORKING_DIR}/mnt" >/dev/null 2>&1 || mount | grep -q "${WORKING_DIR}/mnt"; then
    umount -R -f "${WORKING_DIR}/mnt" 2>/dev/null || true
    umount -R -l "${WORKING_DIR}/mnt" 2>/dev/null || true
  fi
  if [[ -n "${LOOP_DEV:-}" ]]; then
    losetup -d "${LOOP_DEV}" 2>/dev/null || true
  fi
  if [[ -d "${WORKING_DIR}" ]]; then
    rm -rf "${WORKING_DIR}"
  fi
}
trap "cleanup" EXIT INT TERM HUP

mkdir -p "${WORKING_DIR}"

DEPENDENCIES=(curl parted losetup mkfs.vfat mkfs.ext4 bsdtar mkimage xz qemu-aarch64-static)

install_dependencies() {
  local MISSING_DEPS=()
  for cmd in "${DEPENDENCIES[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
      MISSING_DEPS+=("$cmd")
    fi
  done

  if [ ${#MISSING_DEPS[@]} -eq 0 ]; then
    return 0
  fi

  echo -e "Missing commands detected: ${MISSING_DEPS[*]}"
  
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    local OS_ID="${ID:-}"
    local OS_LIKE="${ID_LIKE:-}"
    
    get_pkg_name() {
      case "$1" in
        mkfs.vfat) echo "dosfstools" ;;
        mkfs.ext4) echo "e2fsprogs" ;;
        losetup) echo "util-linux" ;;
        xz)
          if [[ "$OS_ID" == "debian" || "$OS_LIKE" == *"debian"* ]]; then
            echo "xz-utils"
          else
            echo "xz"
          fi
          ;;
        bsdtar)
          if [[ "$OS_ID" == "debian" || "$OS_LIKE" == *"debian"* ]]; then
            echo "libarchive-tools"
          else
            echo "libarchive"
          fi
          ;;
        qemu-aarch64-static) echo "qemu-user-static" ;;
        mkimage)
          if [[ "$OS_ID" == "debian" || "$OS_LIKE" == *"debian"* ]]; then
            echo "u-boot-tools"
          else
            echo "uboot-tools"
          fi
          ;;
        *) echo "$1" ;;
      esac
    }

    local PKGS_TO_INSTALL=()
    for dep in "${MISSING_DEPS[@]}"; do
      PKGS_TO_INSTALL+=("$(get_pkg_name "$dep")")
    done
    
    PKGS_TO_INSTALL=($(echo "${PKGS_TO_INSTALL[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    echo -e "Attempting to auto-install missing packages: ${PKGS_TO_INSTALL[*]}"

    if [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" || "$OS_LIKE" == *"debian"* || "$OS_LIKE" == *"ubuntu"* ]]; then
      export DEBIAN_FRONTEND=noninteractive
      apt update -y && apt install -y "${PKGS_TO_INSTALL[@]}"
    elif [[ "$OS_ID" == "arch" || "$OS_LIKE" == *"arch"* ]]; then
      pacman -Sy --noconfirm "${PKGS_TO_INSTALL[@]}"
    elif [[ "$OS_ID" == "fedora" || "$OS_LIKE" == *"fedora"* ]]; then
      dnf install -y "${PKGS_TO_INSTALL[@]}"
    elif [[ "$OS_ID" == "opensuse"* || "$OS_LIKE" == *"suse"* ]]; then
      zypper ref && zypper in -y "${PKGS_TO_INSTALL[@]}"
    elif [[ "$OS_ID" == "void" ]]; then
      xbps-install -Sy "${PKGS_TO_INSTALL[@]}"
    else
      echo -e "[!] Your distribution ($OS_ID) does not support automatic dependency installation."
      echo -e "[!] Please install the missing dependencies manually and re-run this script."
      exit 1
    fi
    
    for cmd in "${DEPENDENCIES[@]}"; do
      if [[ "$cmd" != "qemu-aarch64-static" ]] && ! command -v "$cmd" &> /dev/null; then
        echo -e "[!] Error: '$cmd' is still missing after auto-installation attempt. Aborting."
        exit 1
      fi
    done
  elif [ -f /etc/slackware-version ]; then
     echo -e "[!] Slackware detected. Auto-installation is not supported without a preferred manager."
     echo -e "[!] Please manually install missing dependencies: ${MISSING_DEPS[*]}"
     exit 1
  else
    echo -e "[!] Unable to detect your distribution. Please install the missing dependencies manually."
    exit 1
  fi
}

install_dependencies

if [ -z "$CI" ] && [ -t 0 ]; then
  echo "========================================="
  echo "        Mira ALARM Desktop Setup         "
  echo "========================================="
  echo "1) Minimal (CLI only - Default)"
  echo "2) XFCE"
  echo "3) MATE"
  echo "4) LXDE"
  echo "5) COSMIC"
  read -p "[?] Choose Desktop Environment [1-5]: " DESKTOP_CHOICE
  case "$DESKTOP_CHOICE" in
    2) DESKTOP_ENV="xfce" ;;
    3) DESKTOP_ENV="mate" ;;
    4) DESKTOP_ENV="lxde" ;;
    5) DESKTOP_ENV="cosmic" ;;
    *) DESKTOP_ENV="minimal" ;;
  esac
else
  DESKTOP_ENV="${DESKTOP_ENV:-minimal}"
fi

# Create IMG file

print_err() {
  echo -e "${1}"
  exit 1
}

print_msg() {
  echo -e "${1}"
}

make_image() {
  mkdir -p ${OUT_DIR}
  cd "${WORKING_DIR}" || exit 1

  if [ ! -f "${ROOTFS_TARBALL_FILE}" ]; then
    print_msg "[1/5] Downloading rootfs tarball..."
    curl -L -o "${ROOTFS_TARBALL_FILE}" "${ROOTFS_URL}"
  fi

  print_msg "[2/5] Setup IMG File"
  dd if=/dev/zero of=${IMG_FILENAME} bs=1M count=${IMG_SIZE} conv=fsync >/dev/null 2>&1
  sync

  parted -s ${IMG_FILENAME} mklabel gpt 2>/dev/null
  parted -s ${IMG_FILENAME} mkpart "ESP" fat32 $((SKIP_SIZE))MiB $((SKIP_SIZE + BOOT_SIZE - 1))MiB 2>/dev/null
  parted -s ${IMG_FILENAME} set 1 esp on 2>/dev/null
  parted -s ${IMG_FILENAME} mkpart "ROOT" ${ROOTFS_TYPE} $((SKIP_SIZE + BOOT_SIZE))MiB 100% 2>/dev/null
  sync

  LOOP_DEV="$(losetup -P -f --show "${IMG_FILENAME}")"
  [[ -n "${LOOP_DEV}" ]] || echo "losetup ${IMG_FILENAME} failed."

  mkfs.vfat -n ${BOOT_LABEL} ${LOOP_DEV}p1 >/dev/null 2>&1

  if [[ "${ROOTFS_TYPE}" == "btrfs" ]]; then
    mkfs.btrfs -f -L ${ROOT_LABEL} -m single ${LOOP_DEV}p2 >/dev/null 2>&1
  else
    mkfs.ext4 -O ^metadata_csum,^64bit -F -q -L ${ROOT_LABEL} -m 0 ${LOOP_DEV}p2 >/dev/null 2>&1
  fi

  # TODO: Write device bootloader

  mkdir -p mnt && sync

  print_msg "[3/5] Mounting IMG File"
  if ! mount ${LOOP_DEV}p2 mnt; then
    # fdisk -l
    print_err "mount ${LOOP_DEV}p2 failed!"
  fi

  mkdir -p mnt/boot && sync

  if ! mount ${LOOP_DEV}p1 mnt/boot; then
    # fdisk -l
    print_err "mount ${LOOP_DEV}p1 failed!"
  fi

  print_msg "[4/5] Copying files"
  cp -af ${BOOT_FILES}/* mnt/boot
  bsdtar -xpf "${ROOTFS_TARBALL_FILE}" -C mnt
  cp -af ${PATCH_FILES}/* mnt/
  [ -f ${SCRIPT_DIR}/lscolors.sh ] && cp ${SCRIPT_DIR}/lscolors.sh mnt/etc && chmod +x mnt/etc/lscolors.sh

  if [ -x "$(command -v qemu-aarch64-static)" ]; then
    print_msg "[ * ] Installing additional filesystem utilities, base packages, tools and DE..."
    cp "$(which qemu-aarch64-static)" mnt/usr/bin/ || true
    
    PKGS="xfsprogs btrfs-progs dosfstools mtools parted base base-devel linux-aarch64-headers wget curl git fastfetch htop plymouth python go lua ruby php grub efibootmgr"

    if [ "$DESKTOP_ENV" == "xfce" ]; then
      PKGS="$PKGS xorg-server xfce4 xfce4-goodies lightdm lightdm-slick-greeter"
    elif [ "$DESKTOP_ENV" == "mate" ]; then
      PKGS="$PKGS xorg-server mate mate-extra lightdm lightdm-slick-greeter"
    elif [ "$DESKTOP_ENV" == "lxde" ]; then
      PKGS="$PKGS xorg-server lxde lightdm lightdm-slick-greeter"
    elif [ "$DESKTOP_ENV" == "cosmic" ]; then
      PKGS="$PKGS xorg-server cosmic cosmic-greeter"
    fi

    # We disable checkspace to avoid chroot mount issues and bypass signature check to speed things up
    chroot mnt /bin/bash -c "pacman -Sy --noconfirm --nocheck $PKGS" || true

    # Enable graphic services and setup slick-greeter if desktop was chosen
    if [[ "$DESKTOP_ENV" =~ ^(xfce|mate|lxde)$ ]]; then
      chroot mnt /bin/bash -c "systemctl enable lightdm" || true
      chroot mnt /bin/bash -c "sed -i 's/^#greeter-session=.*/greeter-session=lightdm-slick-greeter/' /etc/lightdm/lightdm.conf" || true
    elif [ "$DESKTOP_ENV" == "cosmic" ]; then
      chroot mnt /bin/bash -c "systemctl enable cosmic-greeter" || true
    fi

    # UEFI GRUB Setup
    print_msg "[ * ] Configuring UEFI GRUB Bootloader..."
    chroot mnt /bin/bash -c "grub-install --target=arm64-efi --efi-directory=/boot --bootloader-id=Mira --removable" || true
    chroot mnt /bin/bash -c "grub-mkconfig -o /boot/grub/grub.cfg" || true

    rm -f mnt/usr/bin/qemu-aarch64-static
  else
    print_msg "[ ! ] qemu-aarch64-static not found. Make sure xfsprogs is installed in the image manually if you plan to use XFS."
  fi

  if [ -f mnt/etc/_bashrc ] && [ -f mnt/etc/bash.bashrc ]; then
    cat mnt/etc/_bashrc >> mnt/etc/bash.bashrc && rm mnt/etc/_bashrc
  fi

  # Modify mkinitcpio (Arch Linux specific)
  if [ -d mnt/etc/mkinitcpio.d ]; then
    sed -i "s/PRESETS=.*/PRESETS=('default')/" mnt/etc/mkinitcpio.d/linux-aarch64.preset 2>/dev/null || true
    sed -i 's/ALL_kver=.*/ALL_kver="\/boot\/Image"/' mnt/etc/mkinitcpio.d/linux-aarch64.preset 2>/dev/null || true
    sed -i '/^[^#]/ s/\(^fallback_.*$\)/#\1/' mnt/etc/mkinitcpio.d/linux-aarch64.preset 2>/dev/null || true
  fi

  # cleaning up (Arch Linux specific)
  rm -f mnt/boot/{Image.gz,initramfs-linux-fallback.img}
  find ./mnt/boot/dtbs -mindepth 1 ! -regex '^./mnt/boot/dtbs/amlogic\(/.*\)?' -delete 2>/dev/null || true

  print_msg "[5/5] Setup Boot Files"
  mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 -n "S905 autoscript" -d mnt/boot/s905_autoscript.cmd mnt/boot/s905_autoscript 2>/dev/null
  mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 -n "eMMC autoscript" -d mnt/boot/emmc_autoscript.cmd mnt/boot/emmc_autoscript 2>/dev/null
  mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 -n "AML autoscript" -d mnt/boot/aml_autoscript.txt mnt/boot/aml_autoscript 2>/dev/null
  rm mnt/boot/*.cmd
  #mkimage -n "uInitrd Image" -A arm64 -O linux -T ramdisk -C none -d mnt/boot/initramfs-linux.img mnt/boot/uInitrd 2>/dev/null
  #mkimage -n "uImage" -A arm64 -O linux -T kernel -C none -a 0x1080000 -e 0x1080000 -d mnt/boot/Image mnt/boot/uImage 2>/dev/null
  sync

  print_msg "[6/6] Compress IMG File & Finalize"
  xz -9 ${IMG_FILENAME} && mv "${IMG_FILENAME}.xz" "${OUT_DIR}/" 2>/dev/null || true

  echo "======================================================"
  echo " Image has been successfully built!"
  echo " Location: ${OUT_DIR}/${IMG_FILENAME}.xz"
  echo ""
  echo " To flash this image to a USB drive or SD card (≥ 4 GiB), you can use it directly with graphical tools like:"
  echo " - Balena Etcher, Raspberry Pi Imager, GNOME Disks, or Rufus (DD method) for Windows users."
  echo ""
  echo " Or you can use 'dd' via terminal (please substitute /dev/sdX with your actual device):"
  echo "   $ xz -d ${OUT_DIR}/${IMG_FILENAME}.xz"
  echo "   $ sudo dd if=${OUT_DIR}/${IMG_FILENAME} of=/dev/sdX bs=4M conv=fsync status=progress"
  echo "   $ sync"
  echo ""
  echo " WARNING: All existing data on the target device will be destroyed."
  echo " Once booted on your STB, you can optionally install it to the eMMC or SD Card using 'mira-install'."
  echo "======================================================"
}

make_image
