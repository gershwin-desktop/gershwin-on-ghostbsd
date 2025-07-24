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

if [ "${build_type}" = "testing" ] ; then
  PKG_CONF="GhostBSD_Testing"
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
  mkdir -p "${livecd}" "${base}" "${iso}" "${packages_storage}" "${release}" "${cd_root}" >/dev/null 2>/dev/null
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
  ## mount_nullfs ${packages_storage} ${release}/var/cache/pkg
  # shellcheck disable=SC2086
  pkg -r ${release} -R "${cwd}/pkg/" install -y -r ${PKG_CONF}_base ${base_list}
  # shellcheck disable=SC2086
  pkg -r ${release} -R "${cwd}/pkg/" set -y -v 1 ${vital_base}
  rm ${release}/etc/resolv.conf
  ## umount ${release}/var/cache/pkg
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
  # mkdir -p ${release}/usr/local/etc/pkg/repos
  # cp pkg/XLibre.conf ${release}/usr/local/etc/pkg/repos/XLibre.conf
  cp pkg/XLibre.conf ${release}/etc/pkg/XLibre.conf
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
  pkg -c ${release} info -a -s | sort -k2 -hr | head -50
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

downsize()
{
  # Downsize huge llvm package which gets drawn in by xorg
  # Delete everything except libLLVM*
  pkg -c "${release}" info -l llvm19 \
  | grep -v '/usr/local/llvm19/lib/libLLVM.*so.*' \
  | grep '/usr/local/' \
  | sed -e "s|/usr|${release}/usr|g" \
  | sed 's/^[[:space:]]*//' \
  | while IFS= read -r file; do
      rm -f "$file"
    done

  # TODO: Mark llvm9 package as uninstalled so that it gets installed if the user insatlls something that needs it
}

uzip() 
{
  install -o root -g wheel -m 755 -d "${cd_root}"
  ### Fix stray characters in spec.user
  ##sed -i '' -e 's|\\133||g' "${livecd}"/spec.user
  ### Fix paths in filenames by quoting
  ##sed -i '' -e 's|\\040| |g' "${livecd}/spec.user"
  ##sed -i '' -e 's|^\.|".| g' "${livecd}"/spec.user # mtree format needs double quotes
  ##sed -i '' -e 's| type=|" type=|g' "${livecd}"/spec.user
  ##cat "${livecd}"/spec.user
  ##( cd "${release}" ; makefs -b 75% -f 75% -R 262144 "${cd_root}/rootfs.ufs" "${livecd}"/spec.user )
  ( cd "${release}" ; makefs -b 75% -f 75% -R 262144 "${cd_root}/rootfs.ufs" . )
  ls -lh "${cd_root}/rootfs.ufs"
  mkdir -p "${cd_root}/boot/"
  mkuzip -o "${cd_root}/boot/rootfs.uzip" "${cd_root}/rootfs.ufs"

  rm -f "${cd_root}/rootfs.ufs"
  ls -lh "${cd_root}/boot/rootfs.uzip"
}

boot() 
{
  cd "${release}" && tar -cf - boot | tar -xf - -C "${cd_root}"
  mkdir -p "${cd_root}"/bin/ "${cd_root}"/dev "${cd_root}"/etc # TODO: Create all the others here as well instead of keeping them in overlays/boot
  mkdir -p "${cd_root}"/bin/compat/linux/proc "${cd_root}"/bin/compat/linux/sys "${cd_root}"/bin/compat/linux/dev
  cp "${release}"/COPYRIGHT "${cd_root}"/
  chmod +x "${cwd}/overlays/boot/boot/init_script"
  cp -R "${cwd}/overlays/boot/" "${cd_root}"
  cat "${cd_root}"/boot/loader.conf
  # Remove all modules from the ISO that are not required before the root filesystem is mounted
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
  cp "${release}"/etc/login.conf  "${cd_root}"/etc/ # Workaround for: init: login_getclass: unknown class 'daemon'
  tar -cf - rescue | tar -xf - -C "${cd_root}" # /rescue is full of hardlinks
  # Must not try to load tmpfs module in FreeBSD 13 and later, 
  # because it will prevent the one in the kernel from working
  sed -i '' -e 's|^tmpfs_load|# load_tmpfs_load|g' "${cd_root}"/boot/loader.conf
  rm "${cd_root}"/boot/kernel/tmpfs.ko*
  cd -
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
  transmission-create -o "${iso}/${torrent}" -t ${tracker1} -t ${tracker2} -t ${tracker3} "${iso_path}" || true # Exit status: 127
  chmod 644 "${iso}/${torrent}" || true
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
downsize
uzip
boot
image
