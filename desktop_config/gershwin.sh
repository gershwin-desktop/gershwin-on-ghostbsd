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

patch_etc_files
community_setup_liveuser_gershwin
community_setup_autologin_gershwin
gershwin_setup
setup_xinit
final_setup
