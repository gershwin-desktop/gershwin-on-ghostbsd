#!/bin/sh

set -e -u -x

. "${cwd}/common_config/autologin.sh"
. "${cwd}/common_config/base-setting.sh"
. "${cwd}/common_config/finalize.sh"
. "${cwd}/common_config/setuser.sh"

setup_xinit()
{
  chroot "${release}" su "${live_user}" -c "echo 'exec /usr/local/bin/gershwin-x11' > /Users/${live_user}/.xinitrc"
  echo "exec /usr/local/bin/gershwin-x11" > "${release}/root/.xinitrc"
  echo "exec /usr/local/bin/gershwin-x11" > "${release}/usr/share/skel/dot.xinitrc"
}

build_system()
{
  # Build literally as per the instructions in gershwin-build
  chroot "${release}"/root pkg install -y git 
  chroot "${release}"/root git clone https://github.com/gershwin-desktop/gershwin-build.git && cd gershwin-build
  chroot "${release}"/root ./bootstrap.sh
  chroot "${release}"/root ./checkout.sh
  chroot "${release}"/root make install
}

install_system()
{
  # Use precompiled binaries from gershwin-build. NOTE: These can have binary incompatibilities
  # Hack for running on GhostBSD
  ( cd "${release}"/usr/local/lib/ && ln -s libbfd-2.*.so libbfd-2.44.so || true )
  # Install /System (built in gershwin-build repository)
  u="https://api.cirrus-ci.com/v1/artifact/github/gershwin-desktop/gershwin-build/data/system/artifacts/FreeBSD/14/amd64/system.txz"
  curl -sSf "$u" -o "$(basename "$u")"
  tar -xJf system.txz -C "${release}"/
  # Install and enable loginwindow service
  u="https://raw.githubusercontent.com/gershwin-desktop/gershwin-components/refs/heads/main/LoginWindow/loginwindow"
  curl -sSf "$u" -o "${release}"/usr/local/etc/rc.d/loginwindow
  chmod +x "${release}"/usr/local/etc/rc.d/loginwindow
  chroot "${release}" service loginwindow enable
}

patch_etc_files
community_setup_liveuser_gershwin
community_setup_autologin_gershwin
# setup_xinit
build_system
final_setup
