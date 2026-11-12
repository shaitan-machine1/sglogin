
# SGLogin

SGLogin is a login suite - a collection of independent programs that handle seats, sessions, and in future - power management and polkit. It is an alternative to [Systemd-logind][logind], [Elogind][elogind], Seatd, [Turnstile][turnstile].

## Installation

See the [Artix Linux / s6 installation guide](INSTALL.md) for a single-seat setup.

## Repo list
| Repository | Description |
| --- | --- |
| [SGLogin][sglogin] | This overview and [Artix Linux packages](artix-packages/README.md). |
| [Multiseatd][multiseatd] | Seat manager. |
| [Sessiond][sessiond] | Session manager. |
| [Loginctl][loginctl] | SGLogin's CLI interface. |
| [Libseat fork][seatd] | C libseat with inherited-FD support and Multiseatd backend. |
| [greetd fork][greetd] | Display-manager integration with Multiseat. |

# Why does this project exist?
There are 2 kinds of tight coupling that SGLogin removes:
- Session manager and service manager
-  Session manager and seat manager

Removing them, allows SGLogin to solve real problems of desktop Linux.

## Session manager and service manager coupling

### 1. Choosing a user service manager
Systemd-logind spawns `systemd --user` as its user service manager, depending on systemd. Elogind doesn't, and as a consequence, doesn't spawn user service manager.

SGLogin [Sessiond][sessiond] supports any service manager, similar to [Turnstile][turnstile]. Explanation is [here](#how-can-sessiond-support-different-service-managers)

### 2. Giving desktop services the right lifetime
A desktop environment is several services: a compositor, panels, settings services, and so on. Something needs to start, stop, and supervise them.

Desktop environments traditionally handled this themselves. Today, they can use `systemd --user` instead. Using a service manager makes sense, but a user service manager is shared by all of that user's logins. It's good that DEs don't have to maintain a service supervisor, but that introduces new problems. The core problem is that it messes up lifetimes of session and user service manager.

Here's the schema of that:
```text
User
├── systemd --user                          [shared between logins]
│   ├── Shared background services(ssh-agent)
│   ├── Compositor service     ◄───────┐
│   ├── Desktop shell service  ◄───────┤
│   ├── Settings services      ◄───────┤
│   └── PipeWire service               │
│                                      │ requests desktop startup
└── Display manager(greetd / SDDM)     │
    └── Desktop launcher(startplasma)──┘
```

Problems with that:
1. User service manager is one for all your sessions. So you cannot run 2 same-user same-desktop different-seat sessions at the same time.
2. DE has to manually start those services(1 call to start the whole target, but still manual), and thus, depend on systemd. Why can't it autostart when you login? Because they would start on every login, be it graphical or not. And you don't want compositor to start when you connect with SSH.
3. DE launcher has to do a bunch of mumbo-jumbo with setting those services' environments(because user services don't inherit session environment), clearing previous launches data(because previous launches were for different sessions), etc.

This all means maintaining unnecessary code for DE. Instead, SGLogin makes this approach possible:
```text
User
├── User service manager(s6-svscan)              [shared between logins]
│   └── Background services(ssh-agent)
│
└── greetd / SDDM
    └── Selected desktop entry
        └── Session service manager(s6-svscan)   [one per login]
            ├── Compositor
            ├── Desktop shell
            ├── Settings services
            └── PipeWire
```
All the services are actually inside of the session, and that's why they can:
- Inherit env from session manager and display manager(greetd/SDDM) automatically.
- Access seat devices(keyboard, mouse, GPU).
- Startup automatically on login of that specific desktop, because session service manager itself responsible for their startup and supervision. Different DEs have different service manager configurations.

## Seats and sessions coupling
SGLogin's Multiseatd uses Seatd/Libseat compatible connection. First of all, by tight coupling seats and sessions I mean this:

If you ask both Seatd/Libseat and Logind "Who can get access to a keyboard?"
- Seatd/Libseat: a client who holds a libseat connection.
- Logind: A client who started a graphical SESSION, and called [TakeControl][login1] from that SESSION. Only 1 process per graphical session can call TakeControl.

This model is the fundamental problem with Logind, and that's why it has to handle sessions and seats inside one daemon. Seatd/Libseat have much simpler model, and doesn't depend on sessions.

SGLogin introduces a [small upgrade](#1-seatd-connection-inheritance) on upstream Seatd/Libseat. But event with that, it still doesn't solve problem #3.

### 3. Letting several desktop services use the device broker

Back to problem #2 - in fact, any desktop executable can be session service manager under the hood, even if you have systemd as your init system. The real problem is that many desktop services need seat access. Nor Logind, nor inherited Seatd connection can solve this.

To actually have a proper lifetime and seat access like in problem #2 solution, you have to move services like audio(e.g. Pipewire) under session service manager, and make it access seat. And for that to work, you have to give Pipewire and Compositor a connection to seat broker.

SGLogin's Multiseatd gives your authority to your desktop - an authority to create new connections:

#### Context authority schema
```text
User
├── User service manager                         [shared between logins]
│   └── ssh-agent, other shared services
│
└── greetd / SDDM
    │   Receives authority from multiseatd to create device connections
    │   Passes that authority down
    ▼
    Selected desktop entry
    └── Session service manager (s6-svscan)       [one per login]
        │
        ├── with-seat ──── new connection ────► Compositor
        ├── with-seat ──── new connection ────► PipeWire
        │
        ├── without-seat ── no authority  ───► Settings services
        └── without-seat ── no authority  ───► Desktop shell

        with-seat:    creates a connection, starts service
        without-seat: drops authority, starts service without a connection
```

Pipewire doesn't support libseat yet, it accesses audio devices directly, so the only immediate benefit from this, is proper lifetime. After Pipewire will support it, only services with access to seat will be able to access audio devices, which is better.

Refer to multiseatd section


# SGLogin `Multiseatd`

[Multiseatd][multiseatd] is a daemon that is responsible for seat brokering. For device brokering, it exposes seatd-compatible connections, and lets you use normal(almost) libseat connection for that.

A seat is a collection of devices used together: displays, keyboards, mice and other peripherals. A compositor and maybe other desktop services need a way to access those devices.

## Multiseatd depends on 2 new concepts

### 1. Seatd connection inheritance

Seatd normally exposes a socket. Compositor calls libseat, and libseat opens that socket, and gets access to devices.

Problem with this, is that unprivileged compositor must have file permission to open it. And permissions in Unix-like OS are for users, not for individual processes acting as the same user.

So I propose a workflow like this:
1. Seatd socket is only accessible by root, no one else can open it.
2. Greeter is running as root, it connects to Seatd socket.
3. Greeter spawns unprivileged compositor and compositor inherits that connection.
4. Libseat connects to an already open Seatd socket.

No other unprivileged process can access Seatd socket or this connection. This inheritance allows seat access to be completely decoupled from sessions.

### 2. Seat context

With [connection inheritance](#1-seatd-connection-inheritance) alone, you can only inherit 1 connection, ideally you would want to have many connections for each desktop service. 1 inherited connection is not enough for this.

That's why with Multiseatd, Greeter is supposed to create a context, pass it to unprivileged desktop, and desktop can create many connections on it.

Context is a group of connections and [ACL grants](#5-perform-acl-for-non-brokered-devices). Context limits their lifetime - if context dies, ACL grants and connections created on that context die too.

Greeter calls `CreateContext -> context_id, authority_fd` on Multiseatd D-Bus, and passes it down to desktop launcher. Desktop has been given an `authority_fd`, that it can use to create new connections.

#### Authority FD is shared by all services. How are they all gonna use the same authority FD if it's only one connection?
`authority_fd` is not a connection, but more of a key. To get Seatd connection, you must call `CreateConnection(authority_fd) -> seatd_fd` on Multiseatd D-Bus. Desktop service sends authority to Multiseatd as a proof that you hold it, Multiseatd verifies it, and gives you your own dedicated seatd connection.

#### Doesn't that mean desktop services have to know about multiseatd to use that connection?
No. A desktop service definition only has to launch with-seat/without-seat wrapper before executing the actual service. So only adding `exec with-seat pipewire` to your service launcher:
```text
User
├── User service manager                         [shared between logins]
│   └── ssh-agent, other shared services
│
└── greetd / SDDM
    │   Receives authority from multiseatd to create device connections
    │   Passes that authority down
    ▼
    Selected desktop entry
    └── Session service manager (s6-svscan)       [one per login]
        │
        ├── with-seat ──── new connection ────► Compositor
        ├── with-seat ──── new connection ────► PipeWire
        │
        ├── without-seat ── no authority  ───► Settings services
        └── without-seat ── no authority  ───► Desktop shell

        with-seat:    creates a connection, starts service, service inherits Seatd connection
        without-seat: drops authority, starts service without a connection
```

#### What if I want my desktop to just work the same way it does on non-systemd distros?
SGLogin's libseat fork already supports that. Maybe it will get upstreamed soon.

Libseat's Multiseatd backend must see that it has authority fd, call Multiseatd to create a connection, use that Seatd connection normally.


## Other wiring so that it all can work with normal desktop

### 3. Device bindings, available devices advertisement

Ideally, libseat would need to expose inteface that allows to advertise available devices. But:
1. Libseat doesn't have that interface.
2. Most of compositors rely on [libinput][libinput-seats] to know what device belongs to what seat, and use env variable to know what seat they are on. And libinput uses [udev rules][udev] for seat rules.

That's why we have a kinda ugly choice - Multiseat uses [`seat-udev`][seat-udev] library that can read device-seat bindings. It's an abstraction that is an AUTHORITY and ADVERTISER for resolving seat-device mapping.

That means multiseat does NOT have an internal persistent device-seat bindings config.

### 4. Move devices between seats

`seat-udev` allows moving devices between seats. User can access it through SGLogin's [`loginctl seat`][loginctl] interface.
```sh
# Find the device that you need to move
sudo loginctl seat status

# assign this device to seat1
sudo loginctl seat assign /dev/input/event5 seat1
sudo loginctl seat refresh
```

Multiseatd runs as one daemon per seat, that's why you Loginctl's refresh command coordinates all daemons, and makes them first release all the unassigned devices, and then acquire all the assigned devices. There is no automatic refresh.

### 5. Perform ACL for non-brokered devices

I don't really like this part. There are devices that aren't normally brokered(like audio devices). For such devices, we need to set new permissions to their `/dev/...` file with ACL for that specific user. I don't like that because such connections aren't revocable, and make logic of Multiseatd unnecessarily complex.

Before starting desktop session, something(greeter or specific service) has to call `AddAclGrant(authority_fd, uid)` to have ACL grant on that context. Grant can be removed manually `RemoveAclGrant(authority_fd, uid)` or automatically when context gets removed.


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
[greetd]: https://github.com/shaitan-machine1/greetd
[logind]: https://www.freedesktop.org/software/systemd/man/latest/systemd-logind.service.html
[elogind]: https://github.com/elogind/elogind
[login1]: https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.login1.html
[libseat-api]: https://github.com/shaitan-machine1/seatd/blob/master/include/libseat.h
[inherited-fd]: https://github.com/shaitan-machine1/seatd/blob/master/libseat/backend/seatd.c
[libinput-seats]: https://wayland.freedesktop.org/libinput/doc/latest/seats.html
[udev]: https://www.freedesktop.org/software/systemd/man/latest/udev.html
[seat-udev]: https://github.com/shaitan-machine1/multiseatd/tree/master/crates/seat-udev
[pipewire]: https://pipewire.org/
[turnstile]:https://github.com/chimera-linux/turnstile
[issues]: https://github.com/shaitan-machine1/sglogin/issues
[pam]: https://www.linux-pam.org/
[pam-sessiond]: https://github.com/shaitan-machine1/sessiond/tree/master/crates/pam-sessiond
[lib-scoped]: https://github.com/shaitan-machine1/sessiond/tree/master/crates/lib-scoped
[cgroup-v2]: https://docs.kernel.org/admin-guide/cgroup-v2.html
[xdg-runtime-dir]: https://specifications.freedesktop.org/basedir-spec/latest/
