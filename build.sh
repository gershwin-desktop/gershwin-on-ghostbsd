#!/usr/bin/env sh
#
#
# Gershwin-on-GhostBSD Build Script
#
# This script builds the Gershwin Desktop live system based on GhostBSD.
# It handles workspace preparation, base system installation, desktop
# software integration, and ISO image generation.
#
# Requirements: FreeBSD/GhostBSD system with pkg, makefs, mkuzip, etc.

set -e -u

# --- Configuration ---
LABEL="GHOSTBSD"
IMAGE_NAME_PREFIX="gershwin-on-ghostbsd"
WORKDIR="/usr/local/ghostbsd-build"

# Target Environment (Decoupled from Host)
TARGET_VERSION="${TARGET_VERSION:-14}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"
# Map TARGET_ARCH to filename-friendly architecture string
case "${TARGET_ARCH}" in
    amd64) ARCH_STR="x86_64" ;;
    aarch64) ARCH_STR="aarch64" ;;
    *) ARCH_STR="${TARGET_ARCH}" ;;
esac
TARGET_ABI="FreeBSD:${TARGET_VERSION}:${TARGET_ARCH}"
# Branch and OSVERSION mapping
case "${TARGET_VERSION}" in
    14) 
        TARGET_OSVERSION="1403000"
        REPO_BRANCH="stable"
        GHOSTBSD_VERSION="${GHOSTBSD_VERSION:-25.02}"
        ;;
    15) 
        TARGET_OSVERSION="1500028"
        REPO_BRANCH="unstable"
        GHOSTBSD_VERSION="${GHOSTBSD_VERSION:-26.01}"
        ;;
    *)  
        TARGET_OSVERSION="${TARGET_VERSION}00000" 
        REPO_BRANCH="${REPO_BRANCH:-stable}"
        GHOSTBSD_VERSION="${GHOSTBSD_VERSION:-unknown}"
        ;;
esac

RELEASE_DIR="${WORKDIR}/release"
ISO_DIR="${WORKDIR}/iso"
CD_ROOT="${WORKDIR}/cd_root"
PKGS_STORAGE="${WORKDIR}/packages"
LIVE_USER="ghostbsd"
PKG_CONF_NAME="GhostBSD"

# Paths to resources
CWD="$(pwd)"
RESOURCE_DIR="${CWD}/resources"
PKG_LIST_DIR="${RESOURCE_DIR}/packages"
CONFIG_DIR="${WORKDIR}/config/repos"
SCRIPTS_DIR="${RESOURCE_DIR}/scripts"
OVERLAYS_DIR="${RESOURCE_DIR}/overlays"

# --- Environment Fixes ---
export ABI="${TARGET_ABI}"
export OSVERSION="${TARGET_OSVERSION}"
export IGNORE_OSVERSION="yes"
export ASSUME_ALWAYS_YES="yes"

# Unified PKG command
pkg_cmd() {
    env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" \
        pkg -R "${CONFIG_DIR}" "$@"
}

# --- Lifecycle Management ---
cleanup() {
    log "Cleaning up mounts..."
    [ -d "${RELEASE_DIR}/dev" ] && umount "${RELEASE_DIR}/dev" 2>/dev/null || true
    [ -d "${RELEASE_DIR}/proc" ] && umount "${RELEASE_DIR}/proc" 2>/dev/null || true
    [ -d "${RELEASE_DIR}/sys" ] && umount "${RELEASE_DIR}/sys" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log_env() {
    log "Environment: ABI=${ABI}, OSVERSION=${OSVERSION}, REPO_BRANCH=${REPO_BRANCH}, GHOSTBSD_VERSION=${GHOSTBSD_VERSION}"
}

# --- Logging ---
log() {
    printf "\033[1;32m%s [BUILD]\033[0m %s\n" "$(date '+%H:%M:%S')" "$*"
}

error() {
    printf "\033[1;31m%s [ERROR]\033[0m %s\n" "$(date '+%H:%M:%S')" "$*" >&2
    exit 1
}

# --- Initialization ---
[ "$(id -u)" -eq 0 ] || error "This script must be run as root."

setup_workspace() {
    log "Preparing workspace at ${WORKDIR}..."
    
    # Cleanup previous builds
    for dir in "${RELEASE_DIR}" "${CD_ROOT}"; do
        if [ -d "$dir" ]; then
            chflags -R noschg "$dir" >/dev/null 2>&1 || true
            umount -f "${dir}/var/cache/pkg" >/dev/null 2>&1 || true
            umount -f "${dir}/dev" >/dev/null 2>&1 || true
            rm -rf "$dir"
        fi
    done
    
    mkdir -p "${WORKDIR}" "${ISO_DIR}" "${PKGS_STORAGE}" "${RELEASE_DIR}" "${CD_ROOT}" "${CONFIG_DIR}"

    # Generate Repository Configuration
    log "Generating repository configuration for ${TARGET_ABI} on ${REPO_BRANCH} branch..."
    cat > "${CONFIG_DIR}/GhostBSD.conf" <<EOF
GhostBSD_base: {
  url: "https://pkg.ghostbsd.org/${REPO_BRANCH}/${TARGET_ABI}/base",
  enabled: yes
}

GhostBSD_pkg: {
  url: "https://pkg.ghostbsd.org/${REPO_BRANCH}/${TARGET_ABI}/latest",
  enabled: yes
}
EOF
}

# --- Build Stages ---

install_base_system() {
    log "Installing base system packages..."
    mkdir -p "${RELEASE_DIR}/etc" "${RELEASE_DIR}/var/cache/pkg" "${RELEASE_DIR}/var/db/pkg"
    cp /etc/resolv.conf "${RELEASE_DIR}/etc/resolv.conf"
    # Create missing bzip2.pc file required by freetype2
    mkdir -p "${RELEASE_DIR}/usr/local/libdata/pkgconfig"
    cat > "${RELEASE_DIR}/usr/local/libdata/pkgconfig/bzip2.pc" << 'EOF'
prefix=/usr/local
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: bzip2
Description: bzip2 compression library
Version: 1.0.8
Libs: -L${libdir} -lbz2
Cflags: -I${includedir}
EOF
    
    mount_nullfs "${PKGS_STORAGE}" "${RELEASE_DIR}/var/cache/pkg"
    
    pkg_cmd -r "${RELEASE_DIR}" update -f
    pkg_cmd -r "${RELEASE_DIR}" clean -a -y || true
    
    # Filter base packages to only those available in the repo
    log "Filtering base packages..."
    pkg_cmd -r "${RELEASE_DIR}" rquery -r GhostBSD_base "%n" > "${WORKDIR}/available_base.txt"
    grep -Fxf "${WORKDIR}/available_base.txt" "${PKG_LIST_DIR}/base" > "${WORKDIR}/filtered_base.txt" || true
    
    # Use xargs to avoid "Argument list too long" errors
    log "Installing base packages..."
    if [ -s "${WORKDIR}/filtered_base.txt" ]; then
        cat "${WORKDIR}/filtered_base.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" install -y -r GhostBSD_base
    else
        log "Warning: No base packages found to install!"
    fi
    
    log "Setting vital-base packages..."
    pkg_cmd -r "${RELEASE_DIR}" query "%n" > "${WORKDIR}/installed_pkg.txt"
    grep -Fxf "${WORKDIR}/installed_pkg.txt" "${PKG_LIST_DIR}/vital-base" > "${WORKDIR}/filtered_vital_base.txt" || true
    if [ -s "${WORKDIR}/filtered_vital_base.txt" ]; then
        cat "${WORKDIR}/filtered_vital_base.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" set -y -v 1
    fi
    
    umount "${RELEASE_DIR}/var/cache/pkg"
    rm "${RELEASE_DIR}/etc/resolv.conf"
    touch "${RELEASE_DIR}/etc/fstab"
    mkdir -p "${RELEASE_DIR}/cdrom" "${RELEASE_DIR}/mnt" "${RELEASE_DIR}/media"
}

install_gershwin_software() {
    log "Installing Gershwin software environment..."
    cp /etc/resolv.conf "${RELEASE_DIR}/etc/resolv.conf"
    mkdir -p "${RELEASE_DIR}/var/cache/pkg"
    mount_nullfs "${PKGS_STORAGE}" "${RELEASE_DIR}/var/cache/pkg"
    mount -t devfs devfs "${RELEASE_DIR}/dev"
    mkdir -p "${RELEASE_DIR}/proc"
    mount -t procfs proc "${RELEASE_DIR}/proc"

    pkg_cmd -r "${RELEASE_DIR}" update -f
    pkg_cmd -r "${RELEASE_DIR}" clean -a -y || true
    
    # Filter Gershwin and driver packages
    log "Filtering desktop packages..."
    pkg_cmd -r "${RELEASE_DIR}" rquery -r GhostBSD_pkg "%n" > "${WORKDIR}/available_pkg.txt"
    cat "${PKG_LIST_DIR}/gershwin" "${PKG_LIST_DIR}/drivers" | grep -Fxf "${WORKDIR}/available_pkg.txt" > "${WORKDIR}/filtered_pkg.txt" || true

    # Install main packages from the Pkg repo
    log "Installing Gershwin and driver packages..."
    if [ -s "${WORKDIR}/filtered_pkg.txt" ]; then
        cat "${WORKDIR}/filtered_pkg.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" install -y -r GhostBSD_pkg
    else
        log "Warning: No desktop packages found to install!"
    fi
        
    # Set vital packages
    log "Setting vital-gershwin packages..."
    pkg_cmd -r "${RELEASE_DIR}" query "%n" > "${WORKDIR}/installed_pkg_gershwin.txt"
    grep -Fxf "${WORKDIR}/installed_pkg_gershwin.txt" "${PKG_LIST_DIR}/vital-gershwin" > "${WORKDIR}/filtered_vital_gershwin.txt" || true
    if [ -s "${WORKDIR}/filtered_vital_gershwin.txt" ]; then
        cat "${WORKDIR}/filtered_vital_gershwin.txt" | xargs env ABI="${ABI}" OSVERSION="${OSVERSION}" IGNORE_OSVERSION="yes" ASSUME_ALWAYS_YES="yes" pkg -R "${CONFIG_DIR}" -r "${RELEASE_DIR}" set -y -v 1
    fi
    
    # Cleanup
    rm "${RELEASE_DIR}/etc/resolv.conf"
    umount "${RELEASE_DIR}/var/cache/pkg"
    umount "${RELEASE_DIR}/proc" || true
    umount "${RELEASE_DIR}/dev"
}

configure_system() {
    log "Applying system configurations..."

    # Services
    cat <<EFS | xargs -n1 chroot "${RELEASE_DIR}" sysrc
hostname="gershwin"
zfs_enable="YES"
kld_list="linux linux64 cuse fusefs hgame"
linux_enable="YES"
devfs_enable="YES"
devfs_system_ruleset="system"
moused_enable="YES"
dbus_enable="YES"
loginwindow_enable="YES"
webcamd_enable="YES"
cupsd_enable="YES"
avahi_daemon_enable="YES"
avahi_dnsconfd_enable="YES"
ntpd_enable="YES"
ntpd_sync_on_start="YES"
clear_tmp_enable="YES"
dsbdriverd_enable="YES"
initgfx_enable="YES"
initgfx_menu="NO"
smartd_enable="YES"
dshelper_enable="YES"
EFS

    # Initialize Directory Services and create live user
    log "Initializing Directory Services..."
    chroot "${RELEASE_DIR}" sh -c ". /System/Library/Makefiles/GNUstep.sh && dscli init"
    chroot "${RELEASE_DIR}" sh -c ". /System/Library/Makefiles/GNUstep.sh && dscli user add user --realname \"User\" --admin"

    # Sudoers
    sed -i "" -e 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' "${RELEASE_DIR}/usr/local/etc/sudoers"

    # System Patches
    [ -f "${CONFIG_DIR}/devfs.rules.extra" ] && cat "${CONFIG_DIR}/devfs.rules.extra" >> "${RELEASE_DIR}/etc/devfs.rules"
    [ -f "${CONFIG_DIR}/fstab.extra" ] && cat "${CONFIG_DIR}/fstab.extra" >> "${RELEASE_DIR}/etc/fstab"
    mkdir -p "${RELEASE_DIR}/compat/linux/dev/shm" "${RELEASE_DIR}/compat/linux/sys"

    # Branding
    mkdir -p "${RELEASE_DIR}/usr/local/share/ghostbsd"
    echo "gershwin" > "${RELEASE_DIR}/usr/local/share/ghostbsd/desktop"
    echo "${GHOSTBSD_VERSION}" > "${RELEASE_DIR}/etc/ghostbsd-version"
    echo "GhostBSD ${GHOSTBSD_VERSION}" > "${RELEASE_DIR}/etc/version"

    # Update ldconfig cache
    chroot "${RELEASE_DIR}" ldconfig -m /usr/local/lib
}

build_gershwin_components() {
    log "Building Gershwin components from source..."
    [ -d "${WORKDIR}/gershwin-build" ] && rm -rf "${WORKDIR}/gershwin-build"
    git clone --depth 1 https://github.com/gershwin-desktop/gershwin-build "${WORKDIR}/gershwin-build"
    
    # Use absolute path to workspace parent
    PARENT_DIR="/home/user/Developer/repos"
    mkdir -p "${WORKDIR}/gershwin-build/repos"
    
    # List of components that should go into repos/
    for component in gershwin-airwaves gershwin-assets gershwin-components gershwin-docs gershwin-eau-theme gershwin-radiobrowser gershwin-system gershwin-systempreferences gershwin-terminal gershwin-textedit gershwin-welcomesplash gershwin-windowmanager gershwin-workspace libobjc2 libs-back libs-base libs-gui libs-opal libs-quartzcore swift-corelibs-libdispatch tools-make; do
        if [ -d "${PARENT_DIR}/${component}" ]; then
            log "Using local source for ${component}"
            cp -R "${PARENT_DIR}/${component}" "${WORKDIR}/gershwin-build/repos/${component}"
        fi
    done

    # Run checkout for anything missing
    ( cd "${WORKDIR}/gershwin-build" && PINNED=1 ./checkout.sh  )
    
    cp -R "${WORKDIR}/gershwin-build" "${RELEASE_DIR}/root/gershwin-build"
    cp /etc/resolv.conf "${RELEASE_DIR}/etc/resolv.conf"
    
    # Pre-build hack for compatibility
    chroot "${RELEASE_DIR}" sh -c "cd /usr/local/lib && rm -f libbfd-2.43.so libbfd-2.44.so && ln -sf libbfd.so libbfd-2.43.so && ln -sf libbfd.so libbfd-2.44.so || true"
    chroot "${RELEASE_DIR}" ldconfig -m /usr/local/lib

    # Make sure we have devfs and procfs for the build
    mount -t devfs devfs "${RELEASE_DIR}/dev" 2>/dev/null || true
    mkdir -p "${RELEASE_DIR}/proc"
    mount -t procfs proc "${RELEASE_DIR}/proc" 2>/dev/null || true

    # Build inside chroot
    # We use -E to preserve environment if needed, but chroot sh -c is cleaner
    chroot "${RELEASE_DIR}" sh -c "cd /root/gershwin-build && gmake install"
    
    # Cleanup mounts
    umount "${RELEASE_DIR}/proc" || true
    umount "${RELEASE_DIR}/dev" || true
    
    rm -rf "${WORKDIR}/gershwin-build"
    rm -f "${RELEASE_DIR}/etc/resolv.conf"
}

downsize_system() {
    log "Downsizing system (removing heavy build artifacts)..."
    # Reduce LLVM size
    if [ -d "${RELEASE_DIR}/usr/local/llvm19/lib/" ]; then
        mkdir -p "${RELEASE_DIR}/tmp_llvm"
        find "${RELEASE_DIR}/usr/local/llvm19/lib/" -name "libLLVM*.so*" -exec mv {} "${RELEASE_DIR}/tmp_llvm/" \;
        rm -rf "${RELEASE_DIR}/usr/local/llvm19"
        mkdir -p "${RELEASE_DIR}/usr/local/llvm19/lib/"
        mv "${RELEASE_DIR}/tmp_llvm/"* "${RELEASE_DIR}/usr/local/llvm19/lib/"
        rmdir "${RELEASE_DIR}/tmp_llvm"
    fi
}

prepare_boot_env() {
    log "Preparing boot environment..."
    cd "${RELEASE_DIR}" && tar -cf - boot | tar -xf - -C "${CD_ROOT}"
    mkdir -p \
    "${CD_ROOT}/bin" \
    "${CD_ROOT}/compat/linux/dev" \
    "${CD_ROOT}/compat/linux/proc" \
    "${CD_ROOT}/compat/linux/sys" \
    "${CD_ROOT}/dev" \
    "${CD_ROOT}/etc" \
    "${CD_ROOT}/home" \
    "${CD_ROOT}/lib" \
    "${CD_ROOT}/libexec" \
    "${CD_ROOT}/Local" \
    "${CD_ROOT}/media" \
    "${CD_ROOT}/mnt" \
    "${CD_ROOT}/net" \
    "${CD_ROOT}/Network" \
    "${CD_ROOT}/nvidia" \
    "${CD_ROOT}/opt" \
    "${CD_ROOT}/proc" \
    "${CD_ROOT}/rescue" \
    "${CD_ROOT}/root" \
    "${CD_ROOT}/sbin" \
    "${CD_ROOT}/sys" \
    "${CD_ROOT}/System" \
    "${CD_ROOT}/tmp" \
    "${CD_ROOT}/usr" \
    "${CD_ROOT}/uzip" \
    "${CD_ROOT}/var"
    cp "${RELEASE_DIR}"/COPYRIGHT "${CD_ROOT}"/
    chmod +x "${OVERLAYS_DIR}/boot/init_script"
    cp -R "${OVERLAYS_DIR}/boot" "${CD_ROOT}"
    cat "${CD_ROOT}"/boot/loader.conf
    # Remove all modules from the ISO that are not required before the root filesystem is mounted
    # The whole directory /boot/modules is unnecessary
    rm -rf "${CD_ROOT}"/boot/modules/*
    # Remove modules in /boot/kernel that are not loaded at boot time
    find "${CD_ROOT}"/boot/kernel -name '*.ko' \
    -not -name 'cryptodev.ko' \
    -not -name 'firewire.ko' \
    -not -name 'geom_uzip.ko' \
    -not -name 'tmpfs.ko' \
    -not -name 'xz.ko' \
    -delete
    # Compress the kernel
    gzip -f "${CD_ROOT}"/boot/kernel/kernel || true
    rm "${CD_ROOT}"/boot/kernel/kernel || true
    # Compress the modules in a way the kernel understands
    find "${CD_ROOT}"/boot/kernel -type f -name '*.ko' -exec gzip -f {} \;
    find "${CD_ROOT}"/boot/kernel -type f -name '*.ko' -delete
    cp "${RELEASE_DIR}"/etc/login.conf  "${CD_ROOT}"/etc/ # Workaround for: init: login_getclass: unknown class 'daemon'
    tar -cf - rescue | tar -xf - -C "${CD_ROOT}" # /rescue is full of hardlinks
    # Replace identical files with symlinks in rescue
    fdupes -r -S -N "${CD_ROOT}/rescue" || true # -N means do not prompt for confirmation
    ls -lh "${CD_ROOT}/rescue"

    # Comment out splash so that we get the non-color picture built into the kernel instead of a color picture
    # that doesn't match our color scheme
    sed -i '' -e 's|^splash|# splash|g' "${CD_ROOT}"/boot/loader.conf
    
    # Must not try to load tmpfs module in FreeBSD 13 and later, 
    # because it will prevent the one in the kernel from working
    sed -i '' -e 's|^tmpfs_load|# load_tmpfs_load|g' "${CD_ROOT}"/boot/loader.conf
    rm "${CD_ROOT}"/boot/kernel/tmpfs.ko*
    cd -
    
    # https://github.com/freebsd/freebsd-src/blob/5bffa1d2069a05c8346eb34e17a39085fe0bf09b/sbin/init/init.c#L1061
    chmod 755 "${CD_ROOT}/boot/init_script"
}

generate_iso() {
    log "Creating live image (uzip)..."
    ( cd "${RELEASE_DIR}" ; makefs -b 75% -f 75% -R 262144 "${CD_ROOT}/rootfs.ufs" . )
    mkdir -p "${CD_ROOT}/boot"
    mkuzip -A zstd -C 12 -d -o "${CD_ROOT}/boot/rootfs.uzip" "${CD_ROOT}/rootfs.ufs"
    rm -f "${CD_ROOT}/rootfs.ufs"

    log "Generating final ISO image..."
    ISO_PATH="${ISO_DIR}/${IMAGE_NAME_PREFIX}-$(date +%Y%m%d%H%M%S)-${ARCH_STR}.iso"
    # Provide a way to know from the booted ISO what ISO it is
    echo "${IMAGE_NAME_PREFIX}-$(date +%Y%m%d%H%M%S)-${ARCH_STR}.iso" >> "${CD_ROOT}/.iso"

    # Canonical path: run the upstream mkisoimages.sh from its directory so it can
    # reliably source install-boot.sh and produce a hybrid EFI/BIOS image.
    if [ ! -f "${CWD}/resources/scripts/mkisoimages.sh" ]; then
        error "Required script missing: ${CWD}/resources/scripts/mkisoimages.sh"
    fi

    log "Creating ISO using mkisoimages.sh (canonical single path — EFI and BIOS hybrid)..."
    ( cd "${CWD}/resources/scripts" && sh ./mkisoimages.sh -b "${LABEL}" "${ISO_PATH}" "${CD_ROOT}" )

    
    log "ISO created at: ${ISO_PATH}"
    if command -v sha256 >/dev/null; then
        sha256 -q "${ISO_PATH}" > "${ISO_PATH}.sha256"
    elif command -v sha256sum >/dev/null; then
        sha256sum "${ISO_PATH}" > "${ISO_PATH}.sha256"
    fi
}

split()
{
  # units -o "%0.f" -t "2 gigabytes" "bytes"
  THRESHOLD_BYTES=2147483647
  # THRESHOLD_BYTES=1999999999
  ISO_SIZE=$(stat -f%z "${ISO_PATH}")
  if [ $ISO_SIZE -gt $THRESHOLD_BYTES ] ; then
    echo "Size exceeds GitHub Releases file size limit; splitting the ISO"
    sudo split -d -b "$THRESHOLD_BYTES" -a 1 "${ISO_PATH}" "${ISO_PATH}.part"
    echo "Split the ISO, deleting the original"
    rm "${ISO_PATH}"
    ls -l "${ISO_PATH}"*
  fi
}

# --- Main Execution ---
log_env
setup_workspace
install_base_system
install_gershwin_software
configure_system
build_gershwin_components
downsize_system
prepare_boot_env
generate_iso
if [ -n "${CIRRUS_CI:-}" ] ; then
  # On Cirrus CI we want to upload to GitHub Releases which has a 2 GB file size limit,
  # hence we need to split the ISO there if it is too large
  split
fi

log "Build complete!"
