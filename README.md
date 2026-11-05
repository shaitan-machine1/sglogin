# SGLogin

SGLogin is a login suite - a collection of independent programs that handle seats, sessions, and in future power management. It is an alternative to [systemd-logind][logind] and [elogind][elogind].

## Repo list
| Repository | Description |
| --- | --- |
| [sglogin][sglogin] | This overview and [Artix Linux packages](artix-packages/README.md). |
| [multiseatd][multiseatd] | Seat manager. |
| [sessiond][sessiond] | Session manager. |
| [loginctl][loginctl] | SGLogin's CLI interface. |
| [libseat fork][seatd] | C libseat with inherited-FD support. |
| [SDDM fork][sddm] | Display-manager integration with Multiseat. |

# Why does this project exist?

There are 2 couplings/dependencies/problems I want to remove:
1. Logind itself depends on systemd.
2. Systemd-logind/Elogind handle seats, sessions, power management inside one big daemon.

## Why not just use Elogind

For the 2 problems from above:
1. Elogind solves the systemd dependence, but creates a new problem - it doesn't spawn per-user service manager, which is why latest Gnome doesn't work on non-systemd distros.
2. Elogind is still 1 big daemon that handles seats, sessions, power management.


## Why separate seats and sessions at all?

No big reason for that - just for simplicity, and having small composable programs that happen to work together.

By coupling seats and sessions I mean - if you ask both programs:

How can a wayland compositor ask for a keyboard?
- SGLogin: Call [libseat's open_device function][libseat-api].
- Logind: Call [TakeDevice][login1] on Logind D-Dbus.

Who can get access to a keyboard?
- SGLogin: a client who has a libseat connection.
- Logind: A client who started a graphical SESSION, and then called [TakeControl][login1] from that SESSION.

That means:
- SGLogin: if you hold a libseat connection, you can access a seat's device(keyboard) over that connection.
- Logind: if you are inside a graphical session and you're are in control of this session, you can access seat device(keyboard).

Such coupling is the reason why logind has to be so big. And such decoupling is the reason why SGLogin components can be simple.


# SGLogin `Multiseat`

[multiseatd][multiseatd] is a daemon that is responsible for seat brokering.

A seat is a collection of devices used together: displays, keyboards, mice and other peripherals. A compositor needs access to those devices, but it should not need to create or control a login session to get that access.

Ideally, a seat daemon/device broker should:
1. Decide who can access each seat's devices
2. Decide what device belongs to what seat, be the authority that decides it, and advertise the bindings.
3. Allow moving devices between seats
4. React on seat changes immediately, add available devices, revoke unavailable, do it without seat restart.
5. Provide device access upon request
6. Perform ACL for non-brokered devices

## 1. Who can access what each seat's devices

SGLogin Multiseat exposes a root-only D-Bus. But the unprivileged compositor still needs to access it. Multiseat expects this:

A greeter(like [SDDM][sddm]) is running as root, it it supposed to KNOW about Multiseat, open a connection on that seat, and provide the connection to compositor.

So privileged SDDM calls CreateClient(uid, seat_name), Multiseat responds with an FD. FD is a connection to seatd-compatible socket. Privileged SDDM has to transfer this FD to unprivileged compositor. Now unprivileged compositor can talk to that FD using libseat.

### Compositor inherited an FD, how does it know which exactly it is?

Libseat should know about it, not compositor. And there are 2 problems with it:
1. Libseat still has to know what FD it is supposed to talk to.
2. Normal libseat only opens connection by itself, using a socket path, it doesn't support an already open FD.

- For 1: SDDM should get an FD, and also set an ENV variable `SEATD_FD=<fd_number>`.
- For 2: I [forked libseat][seatd], and made it [check for SEATD_FD env variable][inherited-fd], so when it's set, it uses that FD as a seatd socket. I think that change should go into upstream libseat.

## 2. Device bindings, available devices advertisement

Ideally, libseat would need to expose inteface that allows to advertise available devices. But:
1. Libseat doesn't have that interface.
2. Most of compositors rely on [libinput][libinput-seats] to know what device belongs to what seat, and use env variable to know what seat they are on. And libinput uses [udev rules][udev] for seat rules.

That's why we have a kinda ugly choice - Multiseat uses [`seat-udev`][seat-udev] library that can read device-seat bindings. It's an abstraction that is an AUTHORITY and ADVERTISER for resolving seat-device mapping.

That means multiseat does NOT have an internal device-seat bindings config.

## 3. Moving devices between seats

`seat-udev` allows moving devices between seats. User can access it through SGLogin's [`loginctl seat`][loginctl] interface.

## 4. React on seat changes immediately

1. `seat-udev` can listen to udev events - it can say that device is moved or hot-plugged to a new seat.
2. `Multiseat` uses `seat-udev` to listen to those events. It updates each seat's [`seatd-server`][seatd-server] with that new info. `seatd-server` is intentionally kept dumb, but flexible, and able to add new devices and revoke already open devices.

## 5. Provide device access upon request

`Multiseat` uses per seat `seatd-server`. Connections go to seatd-server directly. Its socket is compatible with normal seatd.

## 6. Perform ACL for non-brokered devices

Now this is a part that I don't really like. There are devices that aren't normally brokered, and for them(like audio devices). For such devices, we need to set new permissions to their `/dev/...` file with ACL for that specific user.

This is the only reason for existence of `Multiseat` D-Bus. Without ACL, it could be simple brokering - "Do you have FD? Yes? Good, take the device". But audio devices need **USER** permissions.

For that reason, normal seatd FD minting is not suitable. A greeter has to call Multiseat D-Bus, and specify user id that it's intending to provide access to `CreateClient(uid, seat_name)`. UID is needed ONLY for ACL.

I want all device access to go through a broker, but with services like [pipewire][pipewire] running in the user service manager, makes it kinda hard. I have not yet come up with a solution for this. If someone has an idea for this, I'm open to help, you can [open an issue in this repo][issues].


# SGLogin `Sessiond`

An ideal session manager should:
1. Not require SGLogin-specific integration from any higher stack(SSH, VT, graphical login)
2. Assign session id as an env variable, track every session, so no session is lost or left dangling/ falsely tracked. And also somehow scope that session so we can tell what process belongs to each session, so that no process is left dangling after session is ended.
3. On first/last login create/delete `XDG_RUNTIME_DIR`, spawn/despawn per user service manager - without depending on exact service manager.
4. Have a CLI to reliably end the session
5. Maybe have D-Bus events for `SessionNew` and `SessionRemoved`

## 1. Integration with existing login programs

[Sessiond][sessiond] integrates through [PAM][pam], using [`pam_sessiond`][pam-sessiond]. SSH, console login and display managers already use PAM, so they don't need a sessiond-specific interface.

## 2. Session ID, tracking, scoping

With SGLogin - a session is a group of processes belonging to one login.

Sessiond uses [`lib-scoped`][lib-scoped] as a way to scope the session. Essentially, it's just a daemonless wrapper of [cgroups v2][cgroup-v2], exposing the operations that sessiond needs. Sessiond can answer to any session-related question without asking a daemon, but only by wrapping a `lib-scoped` call, which wraps a cgroups v2 call.

Every process that was created inside that session is a descendant of PAM host, and PAM host is inside a cgroup, which means all session processes will belong to the same cgroup.

Cgroups exists = session exists. Process is inside of `sessiond/user/{uid}/session/{sid} = process is inside this session. Cgroups give sessiond a nice property of being mostly stateless.

Systemd-logind and Elogind use cgroups too.

## 3. `XDG_RUNTIME_DIR` and per-user service manager

Some resources belong to a user, not an individual session:
1. `/run/user/<uid>`, exposed as [`XDG_RUNTIME_DIR`][xdg-runtime-dir].
2. The per-user service manager.

If a user logs in twice, both sessions share these resources. Closing one session should not destroy resources still needed by the other.

### How can sessiond support different service managers?

Sessiond doesn't need to understand the service manager's configuration or service graph. It needs an executable implementing a small protocol:

```text
user-service-manager --ready-fd FD
```

That executable should:
1. Run as the user and remain in the foreground.
2. Start the service manager and perform whatever startup it requires.
3. Write one byte to the supplied FD when ready.
4. On `SIGTERM`, shut down its services and wait for them to exit.

Session open waits for a newly started manager to report readiness. An exit, EOF or timeout before readiness means startup failed.

The entrypoint decides what “ready” means for its service manager. Sessiond doesn't need a backend-specific readiness payload or separate ready/stop commands. It tracks the manager's process identity and contains its processes, so it can request graceful shutdown and escalate cleanup if necessary.

The entrypoint is selected at build time using `SESSIOND_USER_SERVICE_MANAGER`. The current [Artix integration](artix-packages/s6-user-service-manager/README.md) provides an s6 implementation.

## 4. Reliably ending sessions

SGLogin's [`loginctl`][loginctl] provides the administrative interface:

```sh
loginctl session list
loginctl session close SESSION_ID
```

Cleanup first requests graceful termination(same as on closing session with PAM), then escalates if processes remain. Administrative close waits for cleanup and reports failures rather than treating “termination requested” as “session removed”.

## 5. Session events

[Sessiond][sessiond] provides `SessionNew` and `SessionRemoved` D-Bus signals. I don't have any use-case for them right now, but maybe I'll use it at some point. Systemd-logind/Elogind provide it too, so why not?

[sglogin]: https://github.com/shaitan-machine1/sglogin
[multiseatd]: https://github.com/shaitan-machine1/multiseatd
[seatd]: https://github.com/shaitan-machine1/seatd
[sessiond]: https://github.com/shaitan-machine1/sessiond
[loginctl]: https://github.com/shaitan-machine1/loginctl
[sddm]: https://github.com/shaitan-machine1/sddm
[logind]: https://www.freedesktop.org/software/systemd/man/latest/systemd-logind.service.html
[elogind]: https://github.com/elogind/elogind
[login1]: https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.login1.html
[libseat-api]: https://github.com/shaitan-machine1/seatd/blob/master/include/libseat.h
[inherited-fd]: https://github.com/shaitan-machine1/seatd/blob/master/libseat/backend/seatd.c
[libinput-seats]: https://wayland.freedesktop.org/libinput/doc/latest/seats.html
[udev]: https://www.freedesktop.org/software/systemd/man/latest/udev.html
[seat-udev]: https://github.com/shaitan-machine1/multiseat/tree/master/crates/seat-udev
[seatd-server]: https://github.com/shaitan-machine1/multiseat/tree/master/crates/seatd-server
[pipewire]: https://pipewire.org/
[issues]: https://github.com/shaitan-machine1/sglogin/issues
[pam]: https://www.linux-pam.org/
[pam-sessiond]: https://github.com/shaitan-machine1/sessiond/tree/master/crates/pam-sessiond
[lib-scoped]: https://github.com/shaitan-machine1/sessiond/tree/master/crates/lib-scoped
[cgroup-v2]: https://docs.kernel.org/admin-guide/cgroup-v2.html
[xdg-runtime-dir]: https://specifications.freedesktop.org/basedir-spec/latest/
