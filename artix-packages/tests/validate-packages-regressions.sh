#!/bin/bash
# Fast policy fixtures; no archives, makepkg calls, network or installation.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/tests/package-policy.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
expect_failure() {
  local message=$1
  shift
  if "$@" >"$work/result.log" 2>&1; then
    echo "policy accepted invalid fixture: $message" >&2
    exit 1
  fi
  grep -Fq "$message" "$work/result.log"
}

metadata=$'depend = acl\ndepend = udev\ndepend = libseat'
check_multiseat_dependencies "$metadata"
for dependency in acl udev libseat; do
  changed=$(grep -Fvx "depend = $dependency" <<<"$metadata")
  expect_failure "multiseat is missing runtime dependency: $dependency" \
    check_multiseat_dependencies "$changed"
done

account='u greeter - "Graphical greeter" /var/lib/regreet'
check_greeter_account "$account"
expect_failure 'greeter account definition is missing' check_greeter_account ''
for group in video render input tty; do
  expect_failure 'greeter must not have static device group membership' \
    check_greeter_account "$account"$'\nm\tgreeter\t'"$group"
done
user='session include system-local-login'
greeter='session include system-login'
check_greetd_pam "$user" "$greeter"
expect_failure 'greetd PAM central include is missing or duplicated' check_greetd_pam '' "$greeter"
expect_failure 'greetd PAM central include is missing or duplicated' check_greetd_pam "$user"$'\n'"$user" "$greeter"
for module in sessiond rundir elogind turnstile; do
  expect_failure 'greetd must inherit central session policy' check_greetd_pam "$user" "$greeter"$'\nsession optional pam_'"$module.so"
done

check_source_policy $'source = libseat::git+https://example.invalid/repo.git\nsha256sums = SKIP' fixture
check_source_policy 'source = user-service-manager' fixture
expect_failure 'unexpected source checksum' \
  check_source_policy $'source = https://example.invalid/source\nsha256sums = forbidden' fixture
for url in git+ssh://git@example.invalid/repo.git git+http://example.invalid/repo.git git+git://example.invalid/repo.git; do
  expect_failure 'remote build source must use HTTPS' \
    check_source_policy "source = alias::$url" fixture
done

echo 'package-policy regressions passed (18 negative fixtures)'
