#!/bin/bash
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d /tmp/s6-user-service-manager.XXXXXX)
manager=$work/user-service-manager
manager_pid=
cleanup() {
    status=$?
    trap - EXIT
    if [ -n "$manager_pid" ] && kill -0 "$manager_pid" 2>/dev/null; then
        kill -TERM "$manager_pid" 2>/dev/null || true
        wait "$manager_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT

# Isolate even read-only system stores from the host. Only replace the two
# literal store paths; all ownership and source validation stays enabled.
script=$(<"$repo/user-service-manager")
script=${script//\/etc\/s6\/user\//$work/system/}
printf '%s\n' "$script" >"$manager"
chmod 755 "$manager"
mkdir -p "$work/bin" "$work/config/s6/sv/demo" "$work/runtime"
printf 'longrun\n' >"$work/config/s6/sv/demo/type"
printf '#!/bin/sh\nexec sleep 3600\n' >"$work/config/s6/sv/demo/run"
chmod 755 "$work/config/s6/sv/demo/run"

cat >"$work/bin/mock" <<'EOF'
#!/bin/bash
set -euo pipefail
command=${0##*/}
printf '%s %s\n' "$command" "$*" >>"$MOCK_LOG"
[ "${MOCK_FAIL:-}" != "$command" ] || exit 42
case $command in
    s6-rc-repo-init)
        [ "${1:-}" != -U ] || shift
        [ "$1" = -r ]; repo=$2; shift 2
        mkdir -p "$repo/sources"
        printf '%s\n' "$@" >"$repo/stores.list"
        ;;
    s6-rc-set-new)
        [ "$1" = -r ] && [ "$3" = current ]
        mkdir "$2/sources/current"
        ;;
    s6-rc-set-commit)
        [ "$1" = -r ] && [ "$3" = -D ] && [ "$4" = default ] && [ "$5" = current ]
        mkdir -p "$2/compiled"
        cp "$2/sources/current/selection" "$2/compiled/selection" 2>/dev/null || : >"$2/compiled/selection"
        ;;
    s6-rc-set-install)
        [ "$1" = -r ] && [ "$3" = -c ] && [ "$5" = -l ]
        [ "$7" = --no-update ] && [ "$8" = --no-snapshot ] && [ "$9" = current ]
        mkdir "$4.initial"
        cp "$2/compiled/selection" "$4.initial/selection"
        ln -s "$4.initial" "$4"
        ;;
    s6-svscan)
        # The scanner is initially empty, not prepopulated with services.
        [ -z "$(find "$1" -mindepth 1 -print -quit)" ]
        printf '%s\n' "$$" >"$1/.mock-svscan-pid"
        trap 'exit 0' TERM INT HUP
        while :; do sleep 0.05; done
        ;;
    s6-svscanctl)
        [ -f "$2/.mock-svscan-pid" ] || exit 1
        pid=$(<"$2/.mock-svscan-pid")
        case $1 in
            -a) kill -0 "$pid" ;;
            -t) kill -TERM "$pid" ;;
            *) exit 64 ;;
        esac
        ;;
    s6-rc-init)
        [ "$1" = -c ] && [ -L "$2" ] && [ -d "$2" ] && [ "$3" = -l ]
        mkdir "$4"
        cp "$2/selection" "$4/selection"
        ;;
    s6-rc)
        [ "$1" = -l ]
        case $3 in
            -u) [ "$4" = change ] && [ "$5" = default ] ;;
            -da) [ "$4" = change ] ;;
            *) exit 64 ;;
        esac
        ;;
    *) echo "unexpected command: $command" >&2; exit 99 ;;
esac
EOF
chmod 755 "$work/bin/mock"
for command in s6-rc-repo-init s6-rc-set-new s6-rc-set-commit s6-rc-set-install \
    s6-svscan s6-svscanctl s6-rc-init s6-rc s6; do
    ln -s mock "$work/bin/$command"
done
export PATH="$work/bin:/usr/bin:/bin" HOME="$work/home" \
    XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" \
    XDG_RUNTIME_DIR="$work/runtime" MOCK_LOG="$work/commands.log"
state=$XDG_DATA_HOME/s6

start_manager() {
    rm -f "$work/ready"
    mkfifo "$work/ready"
    exec 4<>"$work/ready"
    "$manager" --ready-fd 3 3>"$work/ready" >"$work/manager.log" 2>&1 &
    manager_pid=$!
    if ! IFS= read -r -t 5 ready <&4; then
        cat "$work/manager.log" >&2
        echo 'manager did not become ready' >&2
        exit 1
    fi
    exec 4>&-
    [ -z "$ready" ]
    kill -0 "$manager_pid"
}
stop_manager() {
    kill -TERM "$manager_pid"
    wait "$manager_pid"
    manager_pid=
}
expect_failure() {
    expected=$1
    shift
    if timeout 10 "$@" "$manager" --ready-fd 3 3>"$work/failed-ready" >"$work/failure.log" 2>&1; then
        echo 'manager unexpectedly succeeded' >&2
        exit 1
    else
        status=$?
        [ "$status" -eq "$expected" ] || { cat "$work/failure.log" >&2; exit 1; }
    fi
    [ ! -s "$work/failed-ready" ]
}

if "$manager" --ready-fd nope >/dev/null 2>&1; then exit 1; else [ "$?" -eq 64 ]; fi
expect_failure 65 env XDG_DATA_HOME=relative
start_manager
[ -d "$state/repository/sources/current" ]
[ -L "$state/compiled/current" ]
[ ! -s "$XDG_RUNTIME_DIR/s6/live/selection" ]
grep -Fx -- "s6-rc-repo-init -r $state/repository $XDG_CONFIG_HOME/s6/sv" "$MOCK_LOG"
grep -Fx -- "s6-rc-init -c $state/compiled/current -l $XDG_RUNTIME_DIR/s6/live $XDG_RUNTIME_DIR/s6/scandir" "$MOCK_LOG"
grep -Fx -- "s6-rc -l $XDG_RUNTIME_DIR/s6/live -u change default" "$MOCK_LOG"
boot_target=$(readlink "$state/compiled/current")
stop_manager
grep -Fx -- "s6-rc -l $XDG_RUNTIME_DIR/s6/live -da change" "$MOCK_LOG"

# Pending enable is not an implicit apply on restart.
printf 'demo\n' >"$state/repository/sources/current/selection"
: >"$MOCK_LOG"
start_manager
[ ! -s "$XDG_RUNTIME_DIR/s6/live/selection" ]
[ "$(readlink "$state/compiled/current")" = "$boot_target" ]
! grep -E 's6-rc-set-(new|commit|install) ' "$MOCK_LOG"
grep -Fx -- "s6-rc-repo-init -U -r $state/repository $XDG_CONFIG_HOME/s6/sv" "$MOCK_LOG"
stop_manager

# Simulate an explicitly installed set, then discard all runtime state.
mkdir "$state/compiled/installed"
printf 'demo\n' >"$state/compiled/installed/selection"
ln -sfn installed "$state/compiled/current"
rm -rf "$XDG_RUNTIME_DIR"
mkdir "$XDG_RUNTIME_DIR"
start_manager
grep -Fx demo "$XDG_RUNTIME_DIR/s6/live/selection"
[ "$(readlink "$state/compiled/current")" = installed ]
stop_manager

# Failures after scanner creation close readiness and stop the scanner.
for command in s6-rc-init s6-rc; do
    expect_failure 42 env MOCK_FAIL="$command"
    scanner_pid=$(<"$XDG_RUNTIME_DIR/s6/scandir/.mock-svscan-pid")
    ! kill -0 "$scanner_pid" 2>/dev/null
done

# Source and persistent-state validation must not overwrite installed state.
ln -s /does/not/exist "$XDG_CONFIG_HOME/s6/sv/escaped"
expect_failure 65 env
rm "$XDG_CONFIG_HOME/s6/sv/escaped"
mkdir "$XDG_CONFIG_HOME/s6/sv/default"
printf 'bundle\n' >"$XDG_CONFIG_HOME/s6/sv/default/type"
expect_failure 65 env
rm -rf "$XDG_CONFIG_HOME/s6/sv/default"
[ "$(readlink "$state/compiled/current")" = installed ]
rm "$state/compiled/current"
ln -s /does/not/exist "$state/compiled/current"
expect_failure 65 env
rm "$state/compiled/current"
ln -s installed "$state/compiled/current"

# Every bootstrap failure closes readiness before starting a scanner. A later
# attempt may retry, but must not force-recreate an existing repository.
for command in s6-rc-repo-init s6-rc-set-new s6-rc-set-commit s6-rc-set-install; do
    : >"$MOCK_LOG"
    failed_data=$work/failed-$command
    expect_failure 42 env XDG_DATA_HOME="$failed_data" MOCK_FAIL="$command"
    [ ! -e "$failed_data/s6/compiled/current" ]
    ! grep -E '^s6-svscan ' "$MOCK_LOG"
done
[ -d "$work/failed-s6-rc-set-commit/s6/repository/sources/current" ]

# HOME fallbacks work without XDG config/data overrides or any service sources.
unset XDG_CONFIG_HOME XDG_DATA_HOME
start_manager
[ -L "$HOME/.local/share/s6/compiled/current" ]
[ -d "$HOME/.config/s6/sv" ]
stop_manager
! grep -E '^s6 ' "$MOCK_LOG"
echo 's6 user service manager tests passed'
