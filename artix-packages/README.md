# SGLogin Artix packages

Independently installable components, not a combined daemon or suite metapackage.
Remote sources and Rust dependencies use anonymous HTTPS and exact commits/tags.
No installation, service changes, or deployment is performed by validation.

## Outputs

- `init-logind-none`: empty init-logind/elogind compatibility provider.
- `libseat`: maintained C libseat, inherited SEATD_FD support, no seatd daemon.
  Provides seatd/libseat.so and conflicts with the distribution seatd package.
- `multiseat`: multiseatd, `/usr/libexec/multiseatd/with-seat`, v2 D-Bus policy,
  and complete ordered seat/uaccess rules. No old launcher or v1 API.
- `sessiond`: daemon, PAM module and replaceable per-UID manager launcher.
- `loginctl`: synchronous context/connection/session/scope/PAM administration.
- `greetd-multiseatd`: managed greetd 0.10.3, exact public upstream plus the
  complete `greetd/managed.patch`; isolated exec'd PAM workers, stock ReGreet
  inside Cage. No dependency on an unpublished fork or local source checkout.
- `sglogin-weston-desktop-entry` (`weston-desktop-entry/`): trusted launcher and
  distinct Wayland
  session entry. Depends on Weston and multiseat; ordinary Weston is unchanged.
- `sessiond-s6`, `multiseat-s6`, `greetd-s6`: independent system service outputs.
- `s6-user-service-manager`, optional disabled `dbus-s6-user` and
  `pipewire-s6-user`: unchanged per-UID services, not a desktop supervisor.

There are no SDDM application/service outputs, separate ACL daemon, seatd
server, common PAM-fragment package, retained-session UI or KDE integration.

## Build and validate (normal user only)

```sh
cd PACKAGE_DIRECTORY
makepkg --cleanbuild
```

Install normal distro `cage`, `greetd-regreet` and `weston` packages; none is
patched or rebuilt by these recipes. Verify the selected Cage/wlroots uses the
maintained C libseat and consumes inherited SEATD_FD. The integration tests keep
explicit reproducible source inputs independently of distro packaging.

Build libseat/multiseat/sessiond/loginctl and the selected greeter/desktop-entry
packages before service outputs. Sources including local files deliberately use
SKIP checksums in these build-only recipes; exact remote Git revisions and the
version-controlled maintained patch define the input set.

On a foreign/non-Artix build host without the selected runtime packages, a
build-only `makepkg --cleanbuild --nodeps` can produce archives using already
available development tools. This does **not** validate pacman dependency
resolution or a clean Artix chroot; do not use dependency-ignore flags for
installation or to hide a broken target graph. Record that distinction.

After building all current outputs:

```sh
bash tests/validate-packages.sh
bash tests/validate-packages-regressions.sh
bash tests/validate-packages.sh --check-recipes
```

Archives default to recipe directories; set PKGDEST for a separate directory.
Checks cover metadata regeneration, anonymous HTTPS, source policy, archive
ownership/permissions, component dependencies, central PAM includes, non-static
UID device access, and absence of retired APIs/services. Nothing is installed.
These checks do not establish physical hardware, cgroup or graphical acceptance.

## Device and terminal policy

Multiseat owns `70-uaccess.rules`, `71-seat.rules`, `73-seat-late.rules` and
`74-multiseat-graphical-vt.rules`. Primary DRM/evdev/hidraw are brokered through
independent seatd connections. Render/other eligible uaccess nodes follow
explicit UID grants from the effective context, not connection-count leases.
Do not run another ACL owner. UID ACLs do not isolate same-UID processes and
removing ACLs does not revoke existing direct FDs.

`/etc/conf.d/multiseatd` explicitly selects graphical VT7. Coordinate it with
gettys and the matching root-only tty7/tty0/console rule **before** use; no other
service or controlling-terminal lineage may own that VT. Changing the VT means
reviewing both files, not merely an environment variable. `GRAPHICAL_VT=none`
selects deliberately non-VT-only operation, not a seat0 fallback. No context
allocates a VT. Compositor/UI/application lineages get neither Linux terminal
FDs nor a Linux controlling terminal. PTY applications remain supported.

## Greetd and PAM

The packaged seat0 controller uses `/etc/greetd/seat0.toml` and
`/run/greetd-seat0`. Additional seats need independently named configs, run
folders, service/log definitions and matching seat selection. Do not share
sockets, runfiles or persistent controller lock inodes. Greetd supports one
user login per seat, then starts a fresh ReGreet-in-Cage greeter.

Artix greetd includes system-local-login; that includes system-login. Keep the
normal distro authentication/account/password policy. The greeter uses permit
auth/account and the central session include. Activate pam_sessiond **once** in
system-login using loginctl's existing marked integration, never add a second
entry to greetd or recurse through sessiond-user. Keep pam_env after sessiond:

```sh
loginctl pam status
# Future authorized installation only, as an already-root caller:
loginctl pam activate
```

No recipe edits live PAM. Greetd requires actual sessiond containment even when
the central PAM module is configured fail-open. It verifies runtime ownership
and fails closed if integration is missing. Sessiond owns `/run/user/<uid>`;
`greetd-multiseatd` conflicts with pam_rundir. Review/disable other competing
pam_elogind/pam_turnstile runtime owners in the selected policy. Greeter state
and logs live below `/var/lib/regreet` and `/var/log/regreet`, not a second
runtime manager. Its account has no permanent video/render/input/tty membership.

Choose **Weston (SGLogin)**, not the ordinary Weston entry. Trusted absolute
entrypoints listed in greetd configuration receive full context authority and
must immediately exec with-seat at the final compositor boundary. Optional
entrypoints may be absent; they are checked before use. Never route authority
through profiles, dbus-run-session, loggers or unrelated helpers. With-seat
creates one fresh connection and closes authority before compositor exec.
Cage consumes the seatd FD before executing unmodified ReGreet. No custom UI
backend, new sessiond API or s6-supervised desktop is involved.

## System service graph

```text
dbus-srv + mount-cgroups              -> sessiond-srv
dbus-srv + udevadm                    -> multiseatd-srv
sessiond-srv + multiseatd-srv + mounts -> greetd-seat0-srv
```

Longrun ordering is not proof of D-Bus readiness: greetd fails closed and the
service supervisor can retry after backends are ready. On backend owner/seat
loss it tears down lineages rather than reconstructing old capabilities.
Installing a service output does not enable it or change unrelated user services.
The optional user manager still compiles `$XDG_RUNTIME_DIR/s6` using complete
home/admin/system service-directory overrides and an empty default bundle.

Any future deployment needs a separately authorized review. Never remove Artix
base. Verify `/usr/bin/s6-init` and `/sbin/init` before installation/reboot.
Do not infer fresh PAM/login, physical rendering/input, text-VT or reboot
acceptance from source builds or headless/private-bus fixtures.
