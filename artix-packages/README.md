# SGLogin Artix packages

For a seat0-only installation, see the [installation guide](../INSTALL.md).

Independent components, not a combined daemon or suite metapackage. Sources use
anonymous HTTPS with immutable commits and locked Rust dependencies. Building
never installs packages or changes services, PAM, devices or terminal modes.

## Outputs and source cohort

| Recipe | Output / source |
| --- | --- |
| `libseat` | Maintained C libseat 0.9.3-2; `seatd` commit `42fe3abfdcaefd2d5cbd21f9db803b9da6a2ca6c`; inherited SEATD_FD and explicit native multiseatd backend, no seatd daemon |
| `multiseatd` | v0.4.1, `49834268db6fdfee8f061f6c13392d54b1f6fe83`; both daemon variants, with-seat/without-seat wrappers, per-seat bus policy and seat/uaccess rules |
| `loginctl` | v0.3.2, `6e89a83802dff75e6fb31469d7189165cf7b88e8`; blocking administration and explicit configured-seat refresh |
| `greetd` | `greetd-multiseatd` 0.10.3-6; direct maintained v0.10.3-sglogin.5, `23c1abb3e3656b9aff6b16f554ca2c13431c1c8e`; privileged exec'd PAM hosts |
| `weston-desktop-entry` | `sglogin-weston-desktop-entry`; distinct Weston (SGLogin) entry and strict launcher |
| `seat-services` | Exactly four co-installable seat/display s6 outputs, below |
| `s6-services` | Independent `sessiond-s6` only; session service definitions unchanged |

`sessiond`, `init-logind-none`, `s6-user-service-manager` and optional disabled
`dbus-s6-user`/`pipewire-s6-user` remain separate. Session APIs and their source
pins are unchanged. No ACL daemon, SDDM, standalone seatd server, common PAM
fragment, retained-session UI, KDE integration or s6 desktop supervisor is added.
Cage, greetd-regreet and Weston are ordinary **unmodified distro packages**, not
maintained recipes here. Greetd uses its published fork directly, not a patch
applied to an unrelated upstream snapshot.

## Build (normal user only)

```sh
cd PACKAGE_DIRECTORY
makepkg --cleanbuild
```

Build libseat/multiseatd/loginctl/greetd and the selected desktop entry before
service outputs. Core builds use distinct `target/non-vt` and `target/vt`
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

## Seats, device access and explicit movement

Each explicitly configured seat has its own daemon, contexts, catalog and ACL
registry. The VT binary claims its **complete startup terminal set** until
shutdown, independently of contexts/connections. Root creates immutable-bound
contexts, explicitly deactivates an old context before activating its successor,
and selects foreground separately. Socket arrival/EOF never chooses a context.
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
sessiond-srv + multiseatd-seatN-srv
  + mounts/tmpfiles + root readiness     -> greetd-seatN-srv
```

Seat0 executes `multiseatd-vt --seat seat0 --vts 7,8,9,10,11,12`; seat1 executes
`multiseatd --seat seat1`. Corresponding greetd defaults are seat0/VT7 and non-VT
seat1. Only greetd-seat0-s6 provides/conflicts with init-greetd; seat1 is additive.
Installing outputs does not enable services. Readiness is root ListContexts plus
session inventory, not ordering alone or proof of compositor/driver readiness.

Before enabling seat0, reserve VT7–12 with **no gettys/competing controllers**;
retain recovery outside that set. Its service output owns
`74-multiseatd-vts.rules`, protecting exactly VT7–12, tty0 and console, never all
text terminals. Review conf.d VTS and this rule together. Do not silently stop a
getty or steal a terminal. Unused claimed VTs may be black. Extra explicitly
configured greetd controllers can use other claimed VTs without another default
service output; their runfile/socket/lock and logs must remain seat-plus-VT scoped.

For migration, stop/retire old global access and graphical owners first, remove
old global service outputs/admin seat1 clones explicitly, then install/select the
new per-seat outputs through normal transactions. Do not overlap ACL writers or
claim old cleanup from process disappearance. Preserve unrelated session/user
services, persistent lock inodes, recovery and the selected init packages.

## Greetd, PAM and launch boundaries

The privileged PAM host creates/verifies immutable metadata **before PAM**, opens
the session on Start, grants the final verified UID, activates by root ID and
foregrounds only the initial greeter. Main supervises generic workers, not context
IDs or RPC recovery. Positive device teardown must reach main **before PAM close**;
Pending, timeout or death without proof cannot authorize the next normal Start.
Final PAM/worker results remain separate. Upstream controller exit/short-session
behavior and external restart supervision are preserved; no GPU retry loop.

Artix greetd includes system-local-login/system-login. Activate pam_sessiond
**once centrally**, before pam_env, using `loginctl pam activate` only during an
authorized installation. No recipe edits live PAM or duplicates the module in
greetd. Greetd requires actual sessiond containment and verified runtime ownership,
not merely fail-open PAM success. Do not run pam_rundir/pam_elogind/pam_turnstile
runtime ownership alongside it.

`/etc/tmpfiles.d/regreet.conf` overrides the distro's same-basename fragment,
providing one effective definition for greeter-owned state/log directories at
0700. No second `/usr/lib/tmpfiles.d/greetd.conf` duplicates those paths.

Stock Cage runs stock ReGreet directly through the maintained native C libseat
backend. Greetd passes authority and `LIBSEAT_BACKEND=multiseatd` identically to
greeter and desktop commands; it has no launcher setting, executable allowlist or
special wrapper policy. Unmodified Weston uses the same native backend normally.
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
