#!/bin/bash
set -euo pipefail

# Supply an installed toolchain explicitly, or use the normal PATH. No root,
# system services, user bus, devices or cgroups are used by this test.
export PATH="${S6_USER_TEST_PATH:+$S6_USER_TEST_PATH:}$PATH"
for command in s6 s6-svscan s6-svscanctl s6-rc s6-rc-init s6-rc-repo-init \
    s6-rc-set-new s6-rc-set-commit s6-rc-set-install; do
    command -v "$command" >/dev/null || { echo "missing prerequisite: $command" >&2; exit 77; }
done
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d /tmp/s6-user-frontend.XXXXXX)
manager=$work/user-service-manager
manager_pid=
cleanup() {
    status=$?
    trap - EXIT
    if [ -n "$manager_pid" ] && kill -0 "$manager_pid" 2>/dev/null; then
        kill -TERM "$manager_pid" 2>/dev/null || true
        wait "$manager_pid" 2>/dev/null || true
    fi
    if [ "$status" -ne 0 ]; then
        cat "$work/manager.log" >&2 || true
    fi
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT

# Rebase only the literal system stores so no host service can be imported.
script=$(<"$repo/user-service-manager")
script=${script//\/etc\/s6\/user\//$work/system/}
printf '%s\n' "$script" >"$manager"
chmod 755 "$manager"
export HOME="$work/home" XDG_RUNTIME_DIR="$work/runtime" S6_USER_CONF="$work/s6-user.conf"
unset XDG_DATA_HOME XDG_CONFIG_HOME
mkdir -p "$HOME/.config/s6/sv/demo" "$XDG_RUNTIME_DIR"
printf 'longrun\n' >"$HOME/.config/s6/sv/demo/type"
cat >"$HOME/.config/s6/sv/demo/run" <<'EOF'
#!/bin/sh
printf 'started\n' >>"$HOME/demo-starts"
exec sleep 3600
EOF
chmod 755 "$HOME/.config/s6/sv/demo/run"
cat >"$S6_USER_CONF" <<'EOF'
scandir = ${XDG_RUNTIME_DIR}/s6/scandir
livedir = ${XDG_RUNTIME_DIR}/s6/live
repodir = ${HOME}/.local/share/s6/repository
bootdb = ${HOME}/.local/share/s6/compiled/current
stmpdir = ${XDG_RUNTIME_DIR}/s6/tmp
storelist = ${HOME}/.config/s6/sv
EOF

start_manager() {
    rm -f "$work/ready"
    mkfifo "$work/ready"
    exec 4<>"$work/ready"
    "$manager" --ready-fd 3 3>"$work/ready" >"$work/manager.log" 2>&1 &
    manager_pid=$!
    IFS= read -r -t 20 ready <&4
    exec 4>&-
    [ -z "$ready" ]
    kill -0 "$manager_pid"
}
stop_manager() {
    kill -TERM "$manager_pid"
    wait "$manager_pid"
    manager_pid=
}
frontend() {
    s6 --user --color=no "$@"
}
wait_for_starts() {
    expected=$1
    for ((i=0; i<200; i++)); do
        if [ -f "$HOME/demo-starts" ] && [ "$(wc -l <"$HOME/demo-starts")" -eq "$expected" ]; then
            return
        fi
        sleep 0.01
    done
    echo "expected $expected demo starts" >&2
    exit 1
}
assert_up() {
    frontend live status demo | grep -F '/up/'
}
assert_down() {
    frontend live status demo | grep -F '/down/'
}

# First login is usable but empty; enable is persistent intent, not a start.
start_manager
frontend set status demo | grep -Fx demo/usable
assert_down
[ ! -e "$HOME/demo-starts" ]
frontend set enable -p demo
frontend set status demo | grep -Fx demo/active
assert_down
frontend apply
wait_for_starts 1
assert_up
stop_manager

# Installed state survives complete runtime deletion. A pending disable is
# deliberately not committed or installed by manager startup.
rm -rf "$XDG_RUNTIME_DIR"
mkdir "$XDG_RUNTIME_DIR"
start_manager
wait_for_starts 2
assert_up
frontend set disable demo
stop_manager
start_manager
wait_for_starts 3
assert_up
frontend set status demo | grep -Fx demo/usable
frontend apply
assert_down
stop_manager
start_manager
assert_down
[ "$(wc -l <"$HOME/demo-starts")" -eq 3 ]

# Sync imports newly added definitions directly from the real source store.
mkdir "$HOME/.config/s6/sv/new-service"
printf 'oneshot\n' >"$HOME/.config/s6/sv/new-service/type"
printf '/bin/true\n' >"$HOME/.config/s6/sv/new-service/up"
frontend repository sync
frontend set status new-service | grep -Fx new-service/usable
frontend set enable -p new-service
frontend apply
frontend live status new-service | grep -F '/up/'
stop_manager

# Also accept a repository initialized by frontend before first manager start.
export HOME="$work/other-home"
mkdir -p "$HOME/.config/s6/sv"
frontend repository init
start_manager
frontend set status
[ -L "$HOME/.local/share/s6/compiled/current" ]
stop_manager

echo 'native s6-frontend user manager tests passed'
