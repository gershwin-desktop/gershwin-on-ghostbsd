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

install_system()
{
  # Hack for running on GhostBSD
  ln -s "${release}"/usr/local/lib/libbfd-2.40.so "${release}"/usr/local/lib/libbfd-2.44.so || true
  # Make binaries from FreeBSD 14 usable on FreeBSD 15
  [ -e "${release}"/lib/libutil.so.9 ] || [ ! -e "${release}"/lib/libutil.so.10 ] || ln -s "${release}"libutil.so.10 "${release}"/lib/libutil.so.9
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
install_system
final_setup
