# SGLogin Artix packages

For a seat0-only installation, see the [installation guide](../INSTALL.md).

Independent components, not a combined daemon or suite metapackage. Sources use
anonymous HTTPS with immutable commits and locked Rust dependencies. Building
never installs packages or changes services, PAM, devices or terminal modes.

## Outputs and source cohort

| Recipe | Output / source |
| --- | --- |
| `libseat` | Maintained C libseat 0.9.3-2; `seatd` commit `42fe3abfdcaefd2d5cbd21f9db803b9da6a2ca6c`; inherited SEATD_FD and explicit native multiseatd backend, no seatd daemon |
| `multiseatd` | 0.4.1-2, `11ef8e31d1aacc1c7fa7fa5de7f286cd7a5ddff5`; both daemon variants, exact context masters/public observation, wrappers, per-seat bus policy and seat/uaccess rules |
| `sessiond` | 0.2.0-2, `7f97a43165c6865baa80800748e554c94b4359aa`; valid-only public sessions, local/C SDK, initial PAM seat attributes and caller-resolved scheduled close |
| `lib-sglogin` | 0.1.0-1, `410e7725940116c02d3dfec2d5f697b8621f1f73`; synchronous Rust/C observation library, header and pkg-config metadata |
| `sglogin-polkit` | 128-1, `0a9f280ff6427028fbfc2f5114b52f23b539be92`; native SGLogin provider in polkitd and client libraries; provides `polkit` and its public library SONAMEs |
| `loginctl` | v0.4.0, `f8c241ba7a425e082b8ce0d1b683e28cb6a9ae76`; matching sessiond 0.2.0 SDK/scoped pins, daemon session queries/close and named PAM include |
| `greetd` | `greetd-multiseatd` 0.10.3-8; v0.10.3-sglogin.6, `118a0cfd6da0405cab74fab2bb9aeea885160168`; clean-upstream-based minimal multiseatd integration |
| `weston-desktop-entry` | `sglogin-weston-desktop-entry`; distinct Weston (SGLogin) entry and strict launcher |
| `seat-services` | Exactly four co-installable seat/display s6 outputs, below |
| `s6-services` | Independent `sessiond-s6` only; session service definitions unchanged |

`sessiond`, `init-logind-none`, `s6-user-service-manager` and optional disabled
`dbus-s6-user`/`pipewire-s6-user` remain separate. Sessiond 0.2.0 is a breaking
development API at `org.SGLogin.Sessiond1`, without legacy aliases. Local opening
creates containment/master/SID without a daemon, runtime directory or manager.
Public sessions require their scope, protected readiness marker and exact live
recorded master. Core PAM copies supplied `XDG_SEAT` before daemon readiness;
readiness publishes valid sessions only after committing the marker.
Readiness separately validates runtime and starts eligible managers;
`user_service_manager.min_uid` defaults to 1000 and zero enables every UID.
Below-threshold readiness needs no working manager; the threshold never suppresses
cleanup of existing resources. Only the daemon reads full `sessiond.conf`.
Loginctl uses blocking daemon inventory/master queries; `CloseSession`
waits only for session-tree removal, not subsequent manager/runtime cleanup.
Greetd is independent of sessiond: no source/package/service dependency, config
reader, containment/runtime proof or session cleanup fallback remains. Its normal
PAM stack may use sessiond or another session manager according to system policy.

No ACL daemon, SDDM, standalone seatd server, retained-session
UI, KDE integration or s6 desktop supervisor is added.
Cage, greetd-regreet and Weston are ordinary **unmodified distro packages**, not
maintained recipes here. Greetd uses its published fork directly, not a patch
applied to an unrelated upstream snapshot.

## Build (normal user only)

```sh
cd PACKAGE_DIRECTORY
makepkg --cleanbuild
```

Build libseat/multiseatd/loginctl/greetd and the selected desktop entry before
service outputs. Build `lib-sglogin` before `sglogin-polkit`; the latter requires
its installed or explicitly staged development interface through pkg-config.
Neither library build needs running SGLogin daemons. Core builds use distinct `target/non-vt` and `target/vt`
directories; install respectively `/usr/bin/multiseatd` and
`/usr/bin/multiseatd-vt`. SDK/launcher clients have no executor or VT feature.
The production builds never enable test-support. Sources use SKIP checksums;
exact public Git commits and version-controlled local inputs define the cohort.

On a foreign/non-Artix host without the runtime packages, a normal-user build-only
`makepkg --cleanbuild --nodeps` may use installed development tools. This does
**not** validate target dependency resolution or a clean Artix chroot. Never
use dependency-ignore flags for installation. Build archives are not deployment
or hardware acceptance. Set PKGDEST for archives outside recipe directories.
Recipes retain component/source check phases; there is no separate package test
suite.

Sessiond stages the daemon/launcher, both PAM modules, named `sessiond-session`,
private `sessiond-user`, config and SGLogin D-Bus policy/XML. The SDK mapping is
`libsessiond.so.0` (SONAME `libsessiond.so.0`), linker symlink `libsessiond.so` and
`sessiond.h`. Its checks include private PAM failure/sanitization and staged C
compile/link/export/dependency checks; the SDK has no PAM or executor linkage.
Loginctl's checks cover a private required-core/optional-readiness named include
before `pam_env`. Both recipes use their normal immutable public Git sources and
locked dependencies. Neither package owns `system-login` or installs an activation hook; configuration
and the source-owned named/private PAM stacks are backup-tracked.

## Native polkit packages

`lib-sglogin` installs `libsglogin.so.0`, its linker symlink, `sglogin/login.h`,
`libsglogin.pc` and its GPL-3.0-only license. Its Rust SDK dependencies are locked
to published sessiond/Multiseatd commits; it does not bundle daemon binaries or
require a separate Multiseatd C library.

`sglogin-polkit` retains polkit's normal paths, D-Bus/client/agent interfaces and
LGPL-2.0-or-later license. It provides versioned `polkit` and the existing public
library SONAMEs, and conflicts with `polkit` because they own the same files.
Both polkitd and libpolkit-gobject link libsglogin; no elogind/logind session
provider dependency or runtime fallback is selected.

The recipe, two distribution patches, Artix rules and install hook were copied
from [Artix polkit packaging](https://gitea.artixlinux.org/packages/polkit.git)
at `7666926a661b37aab5580a65eb2918026031b7a8`, not added as a nested repository.
The patches retain explicit GID handling and Artix account defaults; the Artix
option patch is refreshed to update the existing option. PAM configuration,
public library provides, documentation, introspection and upstream tests remain.
As in the Artix baseline, systemd unit files are removed from the archive; this
adds no alternative init service graph or desktop-agent autostart.

A session is local only with a verified exact-master context association on its
selected seat; activity comes from that context's effective access state. Missing
association cannot grant local/active policy defaults. UID/existence queries need
only sessiond. Artix's retained `99-artix.rules` grants some actions independently
of activity, so private provider tests use controlled rules instead.

Package checks include staged C/C++ ABI/export checks and ordinary Meson tests.
The root-owned private-bus provider test skips in normal-user package checks;
run its isolated source harness separately for provider acceptance. Package builds
and archive inspection authorize no installation, PAM changes or service enabling.

## Seats, device access and explicit movement

Each explicitly configured seat has its own daemon, contexts, catalog and ACL
registry. Context masters are immutable authenticated process identities; their
exit withdraws contexts even if delegated capabilities remain open. Read-only
context lookup and change hints are public, with privileged mutation unchanged.
The VT binary claims its **complete startup terminal set** until
shutdown, independently of contexts/connections. Root creates immutable-bound
contexts, withdraws an old context before activating its successor, and selects
foreground separately. Greetd uses checked RemoveContext alone; removal also
clears the active association, so it needs no separate deactivation/ACL removal. Socket arrival/EOF never chooses a context.
Only the eligible foreground active VT context gets managed access; non-VT
instances have one active context and no terminal machinery.

Primary DRM/evdev/hidraw are broker candidates with supported withdrawal checked
before delegation. Render/other eligible uaccess nodes receive explicit context
UID grants. Exact reconciliation preserves base permissions but removes unexpected
named users/groups. No static video/render/input/tty groups or competing ACL owner.
Same-UID/base permissions and already-open direct FDs limit isolation; ACL removal
does not revoke arbitrary existing descriptions.

`/etc/loginctl.conf` defaults to `seats = "seat0"`. Add other seats when configuring
additional instances; the list must cover the complete intended set of owners.
`loginctl seat assign`, `unassign` and `flush` change persistent udev rules only;
run **`loginctl seat refresh` separately**. Refresh pins all configured root owners,
requires successful removal on EVERY participant before ANY addition, and reports
partial errors without retry/rollback. An offline seat blocks additions. Retire or
recover an old owner before removing it from config. Startup inventory is not a
move: finish assignments and old-owner release before destination startup.

## Four-output system service graph

```text
multiseatd-seat0-s6 -> multiseatd-seat0-{srv,log}
multiseatd-seat1-s6 -> multiseatd-seat1-{srv,log}
greetd-seat0-s6     -> greetd-seat0-{srv,log}
greetd-seat1-s6     -> greetd-seat1-{srv,log}

dbus-srv + mount-cgroups                 -> sessiond-srv
dbus-srv + udevadm                       -> multiseatd-seatN-srv
multiseatd-seatN-srv
  + mounts/tmpfiles + root readiness     -> greetd-seatN-srv
```

Seat0 executes `multiseatd-vt --seat seat0 --vts 7,8,9,10,11`; seat1 executes
`multiseatd --seat seat1`. Corresponding greetd defaults are seat0/VT7 and non-VT
seat1. Only greetd-seat0-s6 provides/conflicts with init-greetd; seat1 is additive.
Installing outputs does not enable services. Greetd readiness is root ListContexts,
not session inventory, ordering alone or proof of compositor/driver readiness.

Launch arguments are explicit in the s6 service scripts; these outputs do not
install or read `/etc/conf.d` files. Greetd services select `/etc/greetd/seat0.toml`
and `/etc/greetd/seat1.toml`; seat/VT and greeter settings remain in those TOML
files. Display logs use `/var/log/greetd-seat0` and `/var/log/greetd-seat1`, with
no VT-setting dependency. Custom launch arguments require editing the service
scripts, which package upgrades overwrite.

Before enabling seat0, reserve VT7–11 with **no gettys/competing controllers**;
retain Artix's tty12 recovery getty outside that set. Its service output owns
`74-multiseatd-vts.rules`, protecting exactly VT7–11, tty0 and console, never all
text terminals. Review the VT list in `multiseatd-seat0-srv/run`, this rule and
getty configuration together. Do not silently stop a getty or steal a terminal.
Unused claimed VTs may be black. Extra explicitly configured greetd controllers
can use other claimed VTs without another default
service output; give them distinct general.runfile boot markers and logs.
Upstream PID-qualified GREETD_SOCK paths already distinguish controller sockets;
there is no run_directory setting or new instance-lock mechanism.

For migration, stop/retire old global access and graphical owners first, remove
old global service outputs/admin seat1 clones explicitly, then install/select the
new per-seat outputs through normal transactions. Do not overlap ACL writers or
claim old cleanup from process disappearance. Preserve unrelated session/user
services, persistent lock inodes, recovery and the selected init packages.

## Greetd, PAM and launch boundaries

The privileged exec'd PAM worker creates a context and supplies immutable metadata
**before PAM**, opens the session on Start, grants the final PAM UID, activates
by root ID and foregrounds only the initial VT-backed greeter. It uses checked
RemoveContext alone for normal/error teardown; positive device-removal proof is
sent **before PAM close**. Pending, timeout, owner loss or worker death without
proof stops normal handoff; main has no context IDs or RPC recovery. Final PAM
outcomes remain separate. Ordinary upstream authentication, child supervision,
controller exit/short-session behavior and external restart remain; no GPU retry
loop or replacement supervisor is introduced.

Configure `[multiseatd]` with explicit seat and either positive vt (seat0: 7) or
vt="none" (seat1, API zero). Do not combine this with `[terminal]` or --vt.
Services select --config only; greetd performs no direct Linux VT setup/reset
in this mode. Existing PID sockets and distinct general.runfile markers replace
the former run_directory configuration.

Artix greetd retains the distribution system-local-login/system-login includes.
No recipe edits live PAM, activates a session manager or duplicates a module in
greetd. Overall PAM policy governs login: optional session-management failure
may permit trying the command. Greetd neither requires nor creates a runtime
directory; a compositor can still fail if its ordinary requirements are absent.
When choosing a runtime/session manager, avoid competing ownership according to
that manager's integration instructions. Sessiond remains separately installable;
its selection is not a display-manager requirement. The `sessiond-session`
fragment makes core opening required and daemon readiness optional. Loginctl
manages only the include within `# BEGIN sglogin` / `# END sglogin`, without
validating included policy or migrating old markers. After successful runtime
sanitation, optional readiness failure leaves runtime absent and core SID intact.
No recipe activates the include automatically. Worker crashes may
leave residual sessions/processes; greetd does not sweep them.

`/etc/tmpfiles.d/regreet.conf` overrides the distro's same-basename fragment,
providing one effective definition for greeter-owned state/log directories at
0700. No second `/usr/lib/tmpfiles.d/greetd.conf` duplicates those paths.

Stock Cage runs stock ReGreet directly through the maintained native C libseat
backend. The VT-backed seat0 command uses Cage's `-s` option to allow text-console
switching from the greeter; non-VT seat1 has no terminal switching. Greetd passes
authority and `LIBSEAT_BACKEND=multiseatd` identically to greeter and desktop
commands; it has no launcher setting, executable allowlist or special wrapper
policy. Unmodified Weston uses the same native backend normally.
The command and its pre-libseat loaders/helpers are trusted with full authority.

**Weston (SGLogin)** remains a distinct strict entry. Its desktop file's `Exec=`
directly runs `/usr/libexec/multiseatd/with-seat /usr/bin/weston --backend=drm-backend.so`;
there is no shell wrapper or `TryExec`. The `seat-wrapper` crate supplies `with-seat`
and `without-seat` under `/usr/libexec/multiseatd/`. `with-seat` removes full
authority before compositor exec, passing only a fresh seatd connection.
`without-seat` closes nonstandard inherited FDs and strips seat capabilities and
backend overrides; it refuses socket standard IO, does not remove UID ACL grants,
and is not a sandbox. UI/ordinary applications should inherit neither authority
nor seatd FDs. Both wrappers reject a Linux controlling terminal; PTYs remain
supported.

Deployment requires verified identity, protected current backups/rollback,
non-overlapping recovery and reviewed normal dependency transactions. Never remove
Artix base or the selected init. Verify executable `/usr/bin/s6-init` and
`/sbin/init` resolving to it before each transaction. No physical-host changes,
reboot, password entry or fresh graphical acceptance follows from these builds.
