#!/bin/bash
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
    echo "expected one built archive for $name; set PKGDEST for a custom output directory" >&2
    return 1
  fi
  printf '%s\n' "${candidates[0]}"
}
cache_archive() {
  local archive=$1
  test -f "$archive"
  metadata_cache[$archive]=$(bsdtar -xOf "$archive" .PKGINFO)
  contents_cache[$archive]=$(bsdtar -tf "$archive")
}
info() { printf '%s\n' "${metadata_cache[$1]}"; }
has() { grep -Fqx "$2" <<<"${metadata_cache[$1]}"; }
lacks() { ! grep -Eq "$2" <<<"${metadata_cache[$1]}"; }
files_lack() { ! grep -Eq "$2" <<<"${contents_cache[$1]}"; }
files_have() {
  local archive=$1 path
  shift
  for path in "$@"; do
    grep -Fqx "$path" <<<"${contents_cache[$archive]}"
  done
}

# Routine checks read committed metadata without starting makepkg. Regeneration
# is optional because makepkg configuration startup is comparatively expensive.
for recipe in "$root"/*/PKGBUILD; do
  directory=${recipe%/PKGBUILD}
  metadata=$(<"$directory/.SRCINFO")
  if (( check_recipes )); then
    generated=$(cd "$directory" && makepkg --printsrcinfo)
    diff -u "$directory/.SRCINFO" <(printf '%s\n' "$generated")
  fi
  check_source_policy "$metadata" "$recipe"
  version= release= arch=
  while read -r key _ value; do
    case $key in
      pkgver) version=$value ;;
      pkgrel) release=$value ;;
      arch) arch=$value ;;
    esac
  done <<<"$metadata"
  test -n "$version" && test -n "$release" && test -n "$arch"
  versions[${directory##*/}]=$version-$release
  arches[${directory##*/}]=$arch
done

init=$(package init-logind-none init-logind-none)
libseat=$(package libseat libseat)
multi=$(package multiseat multiseat)
session=$(package sessiond sessiond)
manager=$(package s6-user-service-manager s6-user-service-manager)
dbus_user=$(package dbus-s6-user dbus-s6-user)
pipewire_user=$(package pipewire-s6-user pipewire-s6-user)
loginctl=$(package loginctl loginctl)
greetd=$(package greetd greetd-multiseatd)
weston=$(package weston-desktop-entry sglogin-weston-desktop-entry)
for archive in "$init" "$libseat" "$multi" "$session" "$manager" \
               "$dbus_user" "$pipewire_user" "$loginctl" "$greetd" "$weston"; do
  cache_archive "$archive"
done

has "$init" 'provides = init-logind'
has "$init" 'provides = elogind'
has "$init" 'conflict = init-logind'
has "$init" 'conflict = elogind-s6'
lacks "$init" '^(depend|replace) = '
files_lack "$init" '^usr/(bin|lib)/'

info "$libseat" | grep -Eq '^provides = libseat\.so(=|$)'
has "$libseat" 'provides = seatd=0.9.3'
has "$libseat" 'conflict = seatd'
lacks "$libseat" '^conflict = libseat$'
lacks "$libseat" '^depend = (seatd|multiseat|sessiond|sddm)$'
files_have "$libseat" usr/lib/libseat.so usr/lib/libseat.so.1 usr/include/libseat.h
files_lack "$libseat" '^usr/bin/seatd$'

check_multiseat_dependencies "${metadata_cache[$multi]}"
lacks "$multi" '^(provides|conflict|replace) = '
lacks "$multi" '^depend = (seatd|seat-udev|s6|scoped|sessiond|aclad|sddm)$'
files_have "$multi" \
  usr/bin/multiseatd \
  usr/libexec/multiseatd/with-seat \
  usr/lib/udev/rules.d/70-uaccess.rules \
  usr/lib/udev/rules.d/71-seat.rules \
  usr/lib/udev/rules.d/73-seat-late.rules \
  usr/share/dbus-1/system.d/org.decoupling.multiseatd2.conf \
  usr/lib/udev/rules.d/74-multiseat-graphical-vt.rules \
  etc/conf.d/multiseatd
files_lack "$multi" 'usr/bin/(seatd|seat-launch)$|multiseatd1|dist/s6|multiseatctl|seatctl'

has "$session" 'provides = session-manager'
has "$session" 'depend = user-service-manager'
lacks "$session" '^depend = (aclad|multiseat|seat-udev|scoped|s6|s6-base|s6-rc|coreutils)$'
files_lack "$session" 'sessionctl|etc/s6/user|usr/libexec/user-service-manager'
files_have "$session" \
  etc/sessiond.conf \
  usr/bin/sessiond \
  usr/lib/security/pam_sessiond.so \
  usr/libexec/sessiond/sessiond-user-launcher

has "$manager" 'provides = user-service-manager'
lacks "$manager" '^depend = sessiond$'
files_have "$manager" usr/libexec/user-service-manager
files_lack "$manager" 'flag-recommended'
files_lack "$dbus_user" 'contents.d/default|flag-recommended'
files_lack "$pipewire_user" 'contents.d/default|flag-recommended'
for service in pipewire pipewire-pulse wireplumber pipewire-user; do
  grep -Fq "etc/s6/user/sv/$service/" <<<"${contents_cache[$pipewire_user]}"
done

lacks "$loginctl" '^depend = (aclad|libseat|multiseat|scoped|seat-udev|sessiond)$'
info "$loginctl" | grep -q '^optdepend = multiseat>=0\.3\.0:'
info "$loginctl" | grep -q '^optdepend = sessiond:'
lacks "$loginctl" '^optdepend = (aclad|scoped|seat-udev):'
files_lack "$loginctl" 'multiseatctl|seatctl|sessionctl|scopectl|acladctl'
mode=$(bsdtar -tvf "$loginctl" | awk '$NF == "usr/bin/loginctl" {print $1}')
test "$mode" = '-rwxr-xr-x'

sysusers=$(bsdtar -xOf "$greetd" usr/lib/sysusers.d/greetd.conf)
check_greeter_account "$sysusers"
for dependency in 'multiseat>=0.3.0' sessiond cage greetd-regreet; do has "$greetd" "depend = $dependency"; done
has "$greetd" 'conflict = pam_rundir'
lacks "$greetd" '^depend = (pam_rundir|elogind|turnstile|sddm)$'
files_have "$greetd" usr/bin/greetd etc/greetd/seat0.toml etc/pam.d/greetd etc/pam.d/greetd-greeter
files_lack "$greetd" 'etc/s6|pam_sessiond|pam_aclad|sddm'
check_greetd_pam "$(bsdtar -xOf "$greetd" etc/pam.d/greetd)" "$(bsdtar -xOf "$greetd" etc/pam.d/greetd-greeter)"
python3 "$root/tests/greetd-production-hooks.py" "$greetd"
python3 "$root/tests/weston-entrypoint.py"
for dependency in 'multiseat>=0.3.0' weston; do has "$weston" "depend = $dependency"; done
files_have "$weston" usr/bin/sglogin-weston usr/share/wayland-sessions/sglogin-weston.desktop
files_lack "$weston" 'usr/share/wayland-sessions/weston.desktop|s6|plasma|kwin'
has "$weston" 'pkgname = sglogin-weston-desktop-entry'
for archive in "$greetd" "$weston"; do
  mode=$(bsdtar -tvf "$archive" | awk '$NF ~ /^usr\/bin\// && $1 !~ /^d/ {print $1}')
  [[ -n $mode ]] && ! grep -qv '^-rwxr-xr-x$' <<<"$mode"
done

for name in sessiond-s6 multiseat-s6 greetd-s6; do
  archive=$(package s6-services "$name")
  cache_archive "$archive"
  case $name in
    sessiond-s6)
      lacks "$archive" '^depend = (aclad|multiseat|sddm|scoped|scoped-s6)$'
      files_have "$archive" etc/s6/sv/sessiond-srv/dependencies.d/mount-cgroups
      files_lack "$archive" 'scoped-|aclad-'
      ;;
    multiseat-s6)
      lacks "$archive" '^depend = (aclad|scoped|sddm|sessiond)$'
      files_have "$archive" etc/s6/sv/multiseatd-srv/run
      files_lack "$archive" 'multiseatd-scan|aclad-|scoped-'
      ;;
    greetd-s6)
      has "$archive" 'depend = multiseat-s6'
      has "$archive" 'depend = sessiond-s6'
      has "$archive" 'depend = greetd-multiseatd'
      files_have "$archive" etc/s6/sv/greetd-seat0-srv/run etc/s6/sv/greetd-seat0-srv/dependencies.d/multiseatd-srv etc/s6/sv/greetd-seat0-srv/dependencies.d/sessiond-srv
      files_lack "$archive" 'sddm|s6/user|kwin|plasma'
      ;;
  esac
done

for retired_recipe in sddm cage regreet weston; do
  test ! -e "$root/$retired_recipe/PKGBUILD"
done
! find "$root/s6-services/services" -name '*sddm*' | grep -q .
echo 'context stack package metadata, ownership, and isolation checks passed'
