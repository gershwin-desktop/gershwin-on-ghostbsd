#!/usr/bin/env sh

set -e -u

cwd="$(realpath)"
export cwd

# Only run as superuser
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

# Use find to locate base files and extract filenames directly, converting newlines to spaces
find packages -type f ! -name '*base*' ! -name '*common*' ! -name '*drivers*' -exec basename {} \; | sort -u | tr '\n' ' '

# Find all files in the desktop_config directory
desktop_config_list=$(find desktop_config -type f)
help_function()
{
  printf "Usage: %s -d desktop -r release type\n" "$0"
  printf "\t-h for help\n"
  printf "\t-d Desktop: %s\n" "${desktop_list}"
  printf "\t-b Build type: unstable or release\n"
  printf "\t-t Test: FreeBSD os packages\n"
   exit 1 # Exit script after printing help
}
# Set mate and release to be default
export desktop="mate"
export build_type="release"

while getopts "d:b:th" opt
do
   case "$opt" in
      'd') export desktop="$OPTARG" ;;
      'b') export build_type="$OPTARG" ;;
      't') export desktop="test" ; build_type="test";;
      'h') help_function ;;
      '?') help_function ;;
      *) help_function ;;
   esac
done

if [ "${build_type}" = "test" ] ; then
  PKG_CONF="FreeBSD"
elif [ "${build_type}" = "release" ] ; then
  PKG_CONF="GhostBSD"
elif [ "${build_type}" = "unstable" ] ; then
  PKG_CONF="GhostBSD_Unstable"
else
  printf "\t-b Build type: unstable or release"
  exit 1
fi

# validate desktop packages
if [ ! -f "${cwd}/packages/${desktop}" ] ; then
  echo "The packages/${desktop} file does not exist."
  echo "Please create a package file named '${desktop}'and place it under packages/."
  echo "Or use a valid desktop below:"
  echo "$desktop_list"
  echo "Usage: ./build.sh -d desktop"
  exit 1
fi

# validate desktop
if [ ! -f "${cwd}/desktop_config/${desktop}.sh" ] ; then
  echo "The desktop_config/${desktop}.sh file does not exist."
  echo "Please create a config file named '${desktop}.sh' like these config:"
  echo "$desktop_config_list"
  exit 1
fi

if [ "${desktop}" != "mate" ] ; then
  DESKTOP=$(echo "${desktop}" | tr '[:lower:]' '[:upper:]')
  community="-${DESKTOP}"
else
  community=""
fi

workdir="/usr/local"
livecd="${workdir}/ghostbsd-build"
base="${livecd}/base"
iso="${livecd}/iso"
uzip="${livecd}/uzip"
packages_storage="${livecd}/packages"
release="${livecd}/release"
export release
cd_root="${livecd}/cd_root"
live_user="ghostbsd"
export live_user

time_stamp=""
release_stamp=""
label="GhostBSD"

workspace()
{
  # Unmount any existing mounts and clean up
  umount ${packages_storage} >/dev/null 2>/dev/null || true
  umount ${release}/dev >/dev/null 2>/dev/null || true
  zpool destroy ghostbsd >/dev/null 2>/dev/null || true
  umount ${release} >/dev/null 2>/dev/null || true

  # Remove old build directory if it exists
  if [ -d "${cd_root}" ] ; then
    chflags -R noschg ${cd_root}
    rm -rf ${cd_root}
  fi

  # Detach memory device if previously attached
  mdconfig -d -u 0 >/dev/null 2>/dev/null || true
  
  # Remove old pool image if it exists
  if [ -f "${livecd}/pool.img" ] ; then
    rm ${livecd}/pool.img
  fi

  # Create necessary directories for the build
  mkdir -p ${livecd} ${base} ${iso} ${packages_storage}  ${release}

  # Create a new pool image file of 6GB
  POOL_SIZE='6g'
  truncate -s ${POOL_SIZE} ${livecd}/pool.img
  
  # Attach the pool image as a memory disk
  mdconfig -f ${livecd}/pool.img -u 0

  # Attempt to create the ZFS pool with error handling
  if ! zpool create -O mountpoint="${release}" -O compression=zstd-9 ghostbsd /dev/md0; then
    # Provide detailed error message in case of failure
    echo "Error: Failed to create ZFS pool 'ghostbsd' with the following command:"
    echo "zpool create -O mountpoint='${release}' -O compression=zstd-9 ghostbsd /dev/md0"
    
    # Clean up resources in case of failure
    zpool destroy ghostbsd 2>/dev/null || true
    mdconfig -d -u 0 2>/dev/null || true
    rm -f ${livecd}/pool.img 2>/dev/null || true
    
    # Exit with an error code
    exit 1
  fi
}

base()
{
  if [ "${desktop}" = "test" ] ; then
    base_list="$(cat "${cwd}/packages/test_base")"
    vital_base="$(cat "${cwd}/packages/vital/test_base")"
  else
    base_list="$(cat "${cwd}/packages/base")"
    vital_base="$(cat "${cwd}/packages/vital/base")"
  fi
  mkdir -p ${release}/etc
  cp /etc/resolv.conf ${release}/etc/resolv.conf
  mkdir -p ${release}/var/cache/pkg
  mount_nullfs ${packages_storage} ${release}/var/cache/pkg
  # shellcheck disable=SC2086
  pkg -r ${release} -R "${cwd}/pkg/" install -y -r ${PKG_CONF}_base ${base_list}
  # shellcheck disable=SC2086
  pkg -r ${release} -R "${cwd}/pkg/" set -y -v 1 ${vital_base}
  rm ${release}/etc/resolv.conf
  umount ${release}/var/cache/pkg
  touch ${release}/etc/fstab
  mkdir ${release}/cdrom
}

set_ghostbsd_version()
{
  if [ "${desktop}" = "test" ] ; then
    version="$(date +%Y-%m-%d)"
  else
    version="-$(cat ${release}/etc/version)"
  fi
  iso_path="${iso}/${label}${version}${release_stamp}${time_stamp}${community}.iso"
}

packages_software()
{
  if [ "${build_type}" = "unstable" ] ; then
    cp pkg/GhostBSD_Unstable.conf ${release}/etc/pkg/GhostBSD.conf
  fi
  cp /etc/resolv.conf ${release}/etc/resolv.conf
  mkdir -p ${release}/var/cache/pkg
  mount_nullfs ${packages_storage} ${release}/var/cache/pkg
  mount -t devfs devfs ${release}/dev
  de_packages="$(cat "${cwd}/packages/${desktop}")"
  common_packages="$(cat "${cwd}/packages/common")"
  drivers_packages="$(cat "${cwd}/packages/drivers")"
  vital_de_packages="$(cat "${cwd}/packages/vital/${desktop}")"
  vital_common_packages="$(cat "${cwd}/packages/vital/common")"
  # shellcheck disable=SC2086
  pkg -c ${release} install -y ${de_packages} ${common_packages} ${drivers_packages}
  # shellcheck disable=SC2086
  pkg -c ${release} set -y -v 1 ${vital_de_packages}  ${vital_common_packages}
  mkdir -p ${release}/proc
  mkdir -p ${release}/compat/linux/proc
  rm ${release}/etc/resolv.conf
  umount ${release}/var/cache/pkg
}

fetch_x_drivers_packages()
{
  if [ "${build_type}" = "release" ] ; then
    pkg_url=$(pkg -R pkg/ -vv | grep '/stable.*/latest' | cut -d '"' -f2)
  else
    pkg_url=$(pkg -R pkg/ -vv | grep '/unstable.*/latest' | cut -d '"' -f2)
  fi
  mkdir ${release}/xdrivers
  yes | pkg -R "${cwd}/pkg/" update
  echo """$(pkg -R "${cwd}/pkg/" rquery -x -r ${PKG_CONF} '%n %n-%v.pkg' 'nvidia-driver' | grep -v libva)""" > ${release}/xdrivers/drivers-list
  pkg_list="""$(pkg -R "${cwd}/pkg/" rquery -x -r ${PKG_CONF} '%n-%v.pkg' 'nvidia-driver' | grep -v libva)"""
  for line in $pkg_list ; do
    fetch -o ${release}/xdrivers "${pkg_url}/All/$line"
  done
}

rc()
{
  chroot ${release} touch /etc/rc.conf
  chroot ${release} sysrc hostname='livecd'
  chroot ${release} sysrc zfs_enable="YES"
  chroot ${release} sysrc kld_list="linux linux64 cuse fusefs hgame"
  chroot ${release} sysrc linux_enable="YES"
  chroot ${release} sysrc devfs_enable="YES"
  chroot ${release} sysrc devfs_system_ruleset="devfsrules_common"
  chroot ${release} sysrc moused_enable="YES"
  chroot ${release} sysrc dbus_enable="YES"
  chroot ${release} sysrc lightdm_enable="NO"
  chroot ${release} sysrc webcamd_enable="YES"
  chroot ${release} sysrc firewall_enable="YES"
  chroot ${release} sysrc firewall_type="workstation"
  chroot ${release} sysrc cupsd_enable="YES"
  chroot ${release} sysrc avahi_daemon_enable="YES"
  chroot ${release} sysrc avahi_dnsconfd_enable="YES"
  chroot ${release} sysrc ntpd_enable="YES"
  chroot ${release} sysrc ntpd_sync_on_start="YES"
  chroot ${release} sysrc clear_tmp_enable="YES"
}

ghostbsd_config()
{
  # echo "gop set 0" >> ${release}/boot/loader.rc.local
  mkdir -p ${release}/usr/local/share/ghostbsd
  echo "${desktop}" > ${release}/usr/local/share/ghostbsd/desktop
  # Mkdir for linux compat to ensure /etc/fstab can mount when booting LiveCD
  chroot ${release} mkdir -p /compat/linux/dev/shm
  # Add /boot/entropy file
  chroot ${release} touch /boot/entropy
  # default GhostBSD to local time instead of UTC
  chroot ${release} touch /etc/wall_cmos_clock
}

desktop_config()
{
  # run config for GhostBSD flavor
  sh "${cwd}/desktop_config/${desktop}.sh"
}

uzip() 
{
  install -o root -g wheel -m 755 -d "${cd_root}"
  ( cd "${uzip}" ; makefs -b 75% -f 75% -R 262144 "${cd_root}/rootfs.ufs" ../spec.user )
  mkdir -p "${cd_root}/boot/"
  if [ $MAJOR -gt 13 ] ; then
    mkuzip -o "${cd_root}/boot/rootfs.uzip" "${cd_root}/rootfs.ufs"
  else
    # Use zstd when possible, which is available in FreeBSD beginning with 13 but broken in 14 (FreeBSD bug 267082)
    mkuzip -A zstd -C 15 -d -s 262144 -o "${cd_root}/boot/rootfs.uzip" "${cd_root}/rootfs.ufs"
  fi

  rm -f "${cd_root}/rootfs.ufs"
  
}

boot() 
{
  mkdir -p "${cd_root}"/bin/ ; cp "${uzip}"/bin/freebsd-version "${cd_root}"/bin/
  cp "${uzip}"/COPYRIGHT "${cd_root}"/
  cp -R "${cwd}/overlays/boot/" "${cd_root}"
  cd "${uzip}" && tar -cf - boot | tar -xf - -C "${cd_root}"
  # Remove all modules from the ISO that is not required before the root filesystem is mounted
  # The whole directory /boot/modules is unnecessary
  rm -rf "${cd_root}"/boot/modules/*
  # Remove modules in /boot/kernel that are not loaded at boot time
  find "${cd_root}"/boot/kernel -name '*.ko' \
    -not -name 'cryptodev.ko' \
    -not -name 'firewire.ko' \
    -not -name 'geom_uzip.ko' \
    -not -name 'tmpfs.ko' \
    -not -name 'xz.ko' \
    -delete
  # Compress the kernel
  gzip -f "${cd_root}"/boot/kernel/kernel || true
  rm "${cd_root}"/boot/kernel/kernel || true
  # Compress the modules in a way the kernel understands
  find "${cd_root}"/boot/kernel -type f -name '*.ko' -exec gzip -f {} \;
  find "${cd_root}"/boot/kernel -type f -name '*.ko' -delete
  mkdir -p "${cd_root}"/dev "${cd_root}"/etc # TODO: Create all the others here as well instead of keeping them in overlays/boot
  cp "${uzip}"/etc/login.conf  "${cd_root}"/etc/ # Workaround for: init: login_getclass: unknown class 'daemon'
  cd "${uzip}" && tar -cf - rescue | tar -xf - -C "${cd_root}" # /rescue is full of hardlinks
  if [ $MAJOR -gt 12 ] ; then
    # Must not try to load tmpfs module in FreeBSD 13 and later, 
    # because it will prevent the one in the kernel from working
    sed -i '' -e 's|^tmpfs_load|# load_tmpfs_load|g' "${cd_root}"/boot/loader.conf
    rm "${cd_root}"/boot/kernel/tmpfs.ko*
  fi
}

image()
{
  cd script
  sh mkisoimages.sh -b $label "$iso_path" ${cd_root}
  cd -
  ls -lh "$iso_path"
  cd ${iso}
  shafile=$(echo "${iso_path}" | cut -d / -f6).sha256
  torrent=$(echo "${iso_path}" | cut -d / -f6).torrent
  tracker1="http://tracker.openbittorrent.com:80/announce"
  tracker2="udp://tracker.opentrackr.org:1337"
  tracker3="udp://tracker.coppersurfer.tk:6969"
  echo "Creating sha256 \"${iso}/${shafile}\""
  sha256 "$(echo "${iso_path}" | cut -d / -f6)" > "${iso}/${shafile}"
  transmission-create -o "${iso}/${torrent}" -t ${tracker1} -t ${tracker2} -t ${tracker3} "${iso_path}"
  chmod 644 "${iso}/${torrent}"
  cd -
}

workspace
base
set_ghostbsd_version
if [ "${desktop}" != "test" ] ; then
  packages_software
  fetch_x_drivers_packages
  rc
  desktop_config
  ghostbsd_config
fi
uzip
ramdisk
boot
image
