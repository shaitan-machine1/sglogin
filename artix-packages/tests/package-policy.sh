# Shared policy checks for real package metadata and small regression fixtures.
check_source_policy() {
  local metadata=$1 recipe=$2
  if ! awk '$1 ~ /sums$/ && $3 != "SKIP" { exit 1 }' <<<"$metadata"; then
    echo "unexpected source checksum in $recipe" >&2
    return 1
  fi
  if ! awk '$1 ~ /^source(_.*)?$/ {
    source = $3; sub(/^.*::/, "", source)
    if (source ~ /:\/\// && source !~ /^(git\+)?https:\/\//) exit 1
  }' <<<"$metadata"; then
    echo "remote build source must use HTTPS in $recipe" >&2
    return 1
  fi
}

check_multiseat_dependencies() {
  local metadata=$1 dependency
  for dependency in acl udev libseat; do
    if ! grep -Fqx "depend = $dependency" <<<"$metadata"; then
      echo "multiseat is missing runtime dependency: $dependency" >&2
      return 1
    fi
  done
}

check_greeter_account() {
  local sysusers=$1
  if ! grep -Eq '^[[:space:]]*u[[:space:]]+greeter[[:space:]]' <<<"$sysusers"; then
    echo 'greeter account definition is missing' >&2
    return 1
  fi
  if grep -Eq '^[[:space:]]*m[[:space:]]+greeter[[:space:]]+(video|render|input|tty)([[:space:]]|$)' <<<"$sysusers"; then
    echo 'greeter must not have static device group membership' >&2
    return 1
  fi
}

check_greetd_pam() {
  local user=$1 greeter=$2
  if grep -Eq '^[[:space:]]*-?(session|auth|account|password)[[:space:]].*(pam_(sessiond|rundir|elogind|turnstile|aclad)|sessiond-user)' <<<"$user"$'\n'"$greeter"; then
    echo 'greetd must inherit central session policy without duplicate or competing modules' >&2
    return 1
  fi
  if [[ $(grep -Ec '^session[[:space:]]+include[[:space:]]+system-local-login[[:space:]]*$' <<<"$user") != 1 ]] ||
     [[ $(grep -Ec '^session[[:space:]]+include[[:space:]]+system-login[[:space:]]*$' <<<"$greeter") != 1 ]]; then
    echo 'greetd PAM central include is missing or duplicated' >&2
    return 1
  fi
}
