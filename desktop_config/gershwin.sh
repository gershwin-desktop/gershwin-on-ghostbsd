#!/bin/sh

set -e -u

. "${cwd}/common_config/autologin.sh"
. "${cwd}/common_config/base-setting.sh"
. "${cwd}/common_config/finalize.sh"
. "${cwd}/common_config/setuser.sh"

gershwin_setup()
{
  chmod +x "${cwd}/overlays/uzip/gershwin/files/usr/local/bin/gershwin-x11"
  cp -R "${cwd}/overlays/uzip/gershwin/files/" "${release}"
}

setup_xinit()
{
  chroot "${release}" su "${live_user}" -c "echo 'exec /usr/local/bin/gershwin-x11' > /Users/${live_user}/.xinitrc"
  echo "exec /usr/local/bin/gershwin-x11" > "${release}/root/.xinitrc"
  echo "exec /usr/local/bin/gershwin-x11" > "${release}/usr/share/skel/dot.xinitrc"
}

install_system()
{
  # Make binaries from FreeBSD 14 usable on FreeBSD 15
  [ -e "${release}"/lib/libutil.so.9 ] || [ ! -e "${release}"/lib/libutil.so.10 ] || ln -s "${release}"libutil.so.10 "${release}"/lib/libutil.so.9
  # Install /System (built in gershwin-build repository)
  u="https://api.cirrus-ci.com/v1/artifact/task/5361614007828480/system/artifacts/FreeBSD/14/amd64/system.txz"
  curl -sSf "$u" -o "$(basename "$u")"
  tar -xJf system.txz -C "${release}"/
  # Install and enable loginwindow service
  u="https://raw.githubusercontent.com/gershwin-desktop/gershwin-components/refs/heads/main/LoginWindow/loginwindow"
  curl -sSf "$u" -o "${release}"/usr/loal/etc/rc.d/loginwindow
  chmod +x "${release}"/usr/loal/etc/rc.d/loginwindow
  chroot "${release}" service loginwindow enable
}

patch_etc_files
community_setup_liveuser_gershwin
community_setup_autologin_gershwin
gershwin_setup
setup_xinit
install_system
final_setup
