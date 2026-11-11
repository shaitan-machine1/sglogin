#!/bin/bash
# Inspect archives only; never install or alter services/devices/PAM.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/tests/package-policy.sh"
case ${1:-} in
  '') check_recipes=0 ;;
  --check-recipes) check_recipes=1 ;;
  *) echo "usage: $0 [--check-recipes]" >&2; exit 64 ;;
esac
shopt -s nullglob
declare -A versions arches metadata_cache contents_cache
package() {
  local dir=$1 name=$2 candidate
  local -a candidates=()
  for candidate in "${PKGDEST:-$root/$dir}/$name-${versions[$dir]}-${arches[$dir]}.pkg.tar"*; do
    [[ $candidate == *.sig ]] || candidates+=("$candidate")
  done
  if (( ${#candidates[@]} != 1 )); then
    echo "expected one current archive for $name; set PKGDEST if needed" >&2
    return 1
  fi
  printf '%s\n' "${candidates[0]}"
}
cache_archive() {
  local archive=$1
  metadata_cache[$archive]=$(bsdtar -xOf "$archive" .PKGINFO)
  contents_cache[$archive]=$(bsdtar -tf "$archive")
  # Fakeroot archives must never carry the builder's UID/GID or writable binaries.
  bsdtar --numeric-owner -tvf "$archive" | awk '
    $3 != 0 || $4 != 0 { exit 1 }
    $9 ~ /^usr\/bin\// && $1 !~ /^d/ && $1 != "-rwxr-xr-x" {exit 1}'
}
info() { printf '%s\n' "${metadata_cache[$1]}"; }
has() { grep -Fqx "$2" <<<"${metadata_cache[$1]}"; }
lacks() { ! grep -Eq "$2" <<<"${metadata_cache[$1]}"; }
files_lack() { ! grep -Eq "$2" <<<"${contents_cache[$1]}"; }
files_have() { local archive=$1 path; shift; for path in "$@"; do grep -Fqx "$path" <<<"${contents_cache[$archive]}"; done; }
file() { bsdtar -xOf "$1" "$2"; }

for recipe in "$root"/*/PKGBUILD; do
  directory=${recipe%/PKGBUILD}
  metadata=$(<"$directory/.SRCINFO")
  if (( check_recipes )); then
    generated=$(cd "$directory" && makepkg --printsrcinfo)
    diff -u "$directory/.SRCINFO" <(printf '%s\n' "$generated")
  fi
  check_source_policy "$metadata" "$recipe"
  version= release= arch=
  while read -r key _ value; do case $key in pkgver) version=$value;; pkgrel) release=$value;; arch) arch=$value;; esac; done <<<"$metadata"
  test -n "$version" && test -n "$release" && test -n "$arch"
  versions[${directory##*/}]=$version-$release
  arches[${directory##*/}]=$arch
done

init=$(package init-logind-none init-logind-none)
libseat=$(package libseat libseat)
multi=$(package multiseatd multiseatd)
session=$(package sessiond sessiond)
manager=$(package s6-user-service-manager s6-user-service-manager)
dbus_user=$(package dbus-s6-user dbus-s6-user)
pipewire_user=$(package pipewire-s6-user pipewire-s6-user)
loginctl=$(package loginctl loginctl)
greetd=$(package greetd greetd-multiseatd)
weston=$(package weston-desktop-entry sglogin-weston-desktop-entry)
for archive in "$init" "$libseat" "$multi" "$session" "$manager" "$dbus_user" "$pipewire_user" "$loginctl" "$greetd" "$weston"; do cache_archive "$archive"; done

has "$init" 'provides = init-logind'
has "$init" 'provides = elogind'
has "$init" 'conflict = init-logind'
has "$init" 'conflict = elogind-s6'
lacks "$init" '^(depend|replace) = '
files_lack "$init" '^usr/(bin|lib)/'

info "$libseat" | grep -Eq '^provides = libseat\.so(=|$)'
has "$libseat" 'provides = seatd=0.9.3'
has "$libseat" 'conflict = seatd'
has "$libseat" 'depend = dbus'
lacks "$libseat" '^conflict = libseat$'
lacks "$libseat" '^depend = (seatd|multiseatd|sessiond|sddm)$'
files_have "$libseat" usr/lib/libseat.so usr/lib/libseat.so.1 usr/include/libseat.h
files_lack "$libseat" '^usr/bin/seatd$'

check_multiseatd_dependencies "${metadata_cache[$multi]}"
files_have "$multi" usr/bin/multiseatd usr/bin/multiseatd-vt usr/libexec/multiseatd/seat-launch \
  usr/lib/udev/rules.d/70-uaccess.rules usr/lib/udev/rules.d/71-seat.rules usr/lib/udev/rules.d/73-seat-late.rules \
  usr/share/dbus-1/system.d/org.SGLogin.Multiseatd1.conf
files_lack "$multi" 'with-seat|multiseatd[12]\.conf|etc/s6|etc/conf.d|74-.*rules|multiseatctl|seatctl'
file "$multi" usr/share/dbus-1/system.d/org.SGLogin.Multiseatd1.conf | grep -q 'own_prefix="org.SGLogin.Multiseatd1"'

has "$session" 'provides = session-manager'
has "$session" 'depend = user-service-manager'
lacks "$session" '^depend = (aclad|multiseatd|seat-udev|scoped|s6|s6-base|s6-rc|coreutils)$'
files_lack "$session" 'sessionctl|etc/s6/user|usr/libexec/user-service-manager'
files_have "$session" etc/sessiond.conf usr/bin/sessiond usr/lib/security/pam_sessiond.so usr/libexec/sessiond/sessiond-user-launcher
has "$manager" 'provides = user-service-manager'
lacks "$manager" '^depend = sessiond$'
files_have "$manager" usr/libexec/user-service-manager
files_lack "$manager" 'flag-recommended'
files_lack "$dbus_user" 'contents.d/default|flag-recommended'
files_lack "$pipewire_user" 'contents.d/default|flag-recommended'
for service in pipewire pipewire-pulse wireplumber pipewire-user; do grep -Fq "etc/s6/user/sv/$service/" <<<"${contents_cache[$pipewire_user]}"; done

lacks "$loginctl" '^depend = (aclad|libseat|multiseatd|scoped|seat-udev|sessiond)$'
info "$loginctl" | grep -q '^optdepend = multiseatd>=0\.4\.0:'
info "$loginctl" | grep -q '^optdepend = sessiond:'
files_lack "$loginctl" 'multiseatctl|seatctl|sessionctl|scopectl|acladctl'
file "$loginctl" etc/loginctl.conf | grep -Fxq 'seats = "seat0 seat1"'

check_greeter_account "$(file "$greetd" usr/lib/sysusers.d/greetd.conf)"
for dependency in 'multiseatd>=0.4.0' sessiond cage greetd-regreet; do has "$greetd" "depend = $dependency"; done
has "$greetd" 'conflict = pam_rundir'
lacks "$greetd" '^depend = (pam_rundir|elogind|turnstile|sddm)$'
files_have "$greetd" usr/bin/greetd etc/greetd/seat0.toml etc/greetd/seat1.toml etc/pam.d/greetd etc/pam.d/greetd-greeter etc/tmpfiles.d/regreet.conf
files_lack "$greetd" 'etc/s6|pam_sessiond|pam_aclad|sddm|usr/lib/tmpfiles.d/greetd.conf'
check_greetd_pam "$(file "$greetd" etc/pam.d/greetd)" "$(file "$greetd" etc/pam.d/greetd-greeter)"
file "$greetd" etc/tmpfiles.d/regreet.conf | grep -Fxq 'd /var/lib/regreet 0700 greeter greeter -'
file "$greetd" etc/tmpfiles.d/regreet.conf | grep -Fxq 'd /var/log/regreet 0700 greeter greeter -'
file "$greetd" etc/greetd/seat0.toml | grep -Fxq 'vt = 7'
for seat in seat0 seat1; do
  file "$greetd" etc/greetd/$seat.toml | grep -Fxq "seat = \"$seat\""
  file "$greetd" etc/greetd/$seat.toml | grep -Fxq 'launcher = "/usr/libexec/multiseatd/seat-launch"'
done
python3 "$root/tests/greetd-production-hooks.py" "$greetd"
python3 "$root/tests/weston-entrypoint.py"
for dependency in 'multiseatd>=0.4.0' weston; do has "$weston" "depend = $dependency"; done
files_have "$weston" usr/bin/sglogin-weston usr/share/wayland-sessions/sglogin-weston.desktop
files_lack "$weston" 'usr/share/wayland-sessions/weston.desktop|s6|plasma|kwin'

archive=$(package s6-services sessiond-s6)
cache_archive "$archive"
lacks "$archive" '^depend = (aclad|multiseatd|sddm|scoped|scoped-s6)$'
files_have "$archive" etc/s6/sv/sessiond-srv/dependencies.d/mount-cgroups
files_lack "$archive" 'multiseatd|greetd|sddm|scoped-|aclad-'
mapfile -t outputs < <(awk '$1=="pkgname" {print $3}' "$root/seat-services/.SRCINFO")
check_seat_service_outputs "${outputs[@]}"
declare -A owned
for name in "${outputs[@]}"; do
  archive=$(package seat-services "$name")
  cache_archive "$archive"
  service=${name%-s6}
  files_have "$archive" "etc/s6/sv/$service-srv/run" "etc/s6/sv/$service-log/run"
  files_lack "$archive" 'sddm|s6/user|kwin|plasma|seatd-scan|etc/s6/sv/sessiond'
  file "$archive" "etc/s6/sv/$service-srv/producer-for" | grep -Fxq "$service-log"
  file "$archive" "etc/s6/sv/$service-log/consumer-for" | grep -Fxq "$service-srv"
  file "$archive" "etc/s6/sv/$service-log/pipeline-name" | grep -Fxq "$service"
  while IFS= read -r path; do
    [[ $path == */ || $path == .* || $path == usr/share/licenses/* ]] && continue
    test -z "${owned[$path]:-}"
    owned[$path]=$name
  done <<<"${contents_cache[$archive]}"
  case $service in
    multiseatd-seat0)
      file "$archive" etc/s6/sv/$service-srv/run | grep -Fq '/usr/bin/multiseatd-vt --seat seat0 --vts "$VTS"'
      file "$archive" etc/conf.d/multiseatd-seat0 | grep -Fxq 'VTS=7,8,9,10,11,12'
      file "$archive" usr/lib/udev/rules.d/74-multiseatd-vts.rules | python3 "$root/tests/vt-reservation.py"
      ;;
    multiseatd-seat1)
      file "$archive" etc/s6/sv/$service-srv/run | grep -Fxq 'exec /usr/bin/multiseatd --seat seat1'
      files_lack "$archive" '^usr/lib/udev/|^etc/conf.d/'
      ;;
    greetd-*)
      seat=${service#greetd-}
      has "$archive" "depend = multiseatd-$seat-s6"
      has "$archive" 'depend = sessiond-s6'
      has "$archive" 'depend = greetd-multiseatd'
      has "$archive" 'depend = loginctl'
      files_have "$archive" "etc/s6/sv/$service-srv/dependencies.d/multiseatd-$seat-srv" "etc/s6/sv/$service-srv/dependencies.d/sessiond-srv"
      file "$archive" etc/s6/sv/$service-srv/run | grep -Fq "loginctl seat context $seat list"
      file "$archive" etc/s6/sv/$service-srv/run | grep -Fq -- "--seat $seat"
      if [[ $seat == seat0 ]]; then
        has "$archive" 'provides = init-greetd'
        file "$archive" etc/s6/sv/$service-srv/run | grep -Fq -- '--vt "$VT"'
      else
        lacks "$archive" '^(provides|conflict) = init-'
        ! file "$archive" etc/s6/sv/$service-srv/run | grep -q -- '--vt'
      fi
      ;;
  esac
done
for retired in sddm cage regreet weston multiseat; do test ! -e "$root/$retired/PKGBUILD"; done
test ! -e "$root/greetd/managed.patch"
echo 'Per-seat package pins, archives, terminal policy, production hooks and four-output isolation passed'
