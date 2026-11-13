# Install SGLogin on Artix Linux (s6)
This guide sets up only one graphical seat `seat0`. Multiseatd supports multiple seats, but I'll write guide for that later.

## Init system

This guide assumes you:
1. Have s6 as your init system
2. Want s6 as your user service manager

If your init system is not s6, you can make your own services in your init system and it'll work.

With this setup, s6 will be your user service manager regardless of what init system you have. If you want a different user service manager, make your own service manager entrypoint.

## Compositor
Your desktop's compositor must support **normal libseat**.

Weston, Niri, WLRoots(Sway, Hyprland, Wayfire, DWL, LabWC, Cage, etc.) should work.

Kwin(KDE), Mutter(Gnome) will not work(yet).

For greeter, this guide will use normal ReGreet, normal Cage, and modified Greetd that supports multiseatd.


## 1. Prepare the system

Logout of your graphical session, switch to any VT in range 1-6. For example Ctrl+Alt+F2 for VT2. Log into your user account.

Stop and disable elogind and your display manager, example for SDDM:
```sh
sudo s6 live stop sddm elogind
sudo s6 set disable sddm elogind
sudo s6 apply
```

Remove turnstile, seatd, or any other seat or session manager if you use one:
```sh
sudo pacman -Rns turnstile turnstile-s6 seatd
```

Install the build tools and stock greeter/audio dependencies:
```sh
sudo pacman -S --needed base-devel git rust meson ninja dbus-s6 \
  cage greetd-regreet pipewire pipewire-pulse wireplumber

git clone https://github.com/shaitan-machine1/sglogin.git
cd sglogin/artix-packages
```


## 2. Build and install the packages

Build and install each package
```bash
for recipe in init-logind-none s6-user-service-manager libseat multiseatd \
  sessiond loginctl greetd dbus-s6-user pipewire-s6-user s6-services; do
  (cd "$recipe" && makepkg --cleanbuild --syncdeps --install) || break
done
```

Elogind is hard to remove, because `base` package depends on it. `init-logind-none` is a workaround package that satisfies that dependency and allows elogind to actually be removed.

Only continue when **all** recipes above have succeeded. Build and install multiseatd-seat0-s6 and greetd-seat0-s6 services:
```sh
(cd seat-services && makepkg --cleanbuild --syncdeps)
sudo pacman -U seat-services/multiseatd-seat0-s6-*.pkg.tar.zst \
  seat-services/greetd-seat0-s6-*.pkg.tar.zst
```


## 3. Activate Sessiond's PAM integration

```sh
sudo loginctl pam activate
loginctl pam status
```
This adds `pam_sessiond` to `/etc/pam.d/system-login`, before `pam_env`.

Add this line to `/etc/security/pam_env.conf`

```text
DBUS_SESSION_BUS_ADDRESS DEFAULT=unix:path=${XDG_RUNTIME_DIR}/bus
```

## 4. Start the seat0 login screen

The defaults use VT7 for greetd and reserve VT7–12 for Multiseatd. If something already uses VT7–11, disable it or change `VTS` in `/etc/conf.d/multiseatd-seat0` and the matching VT udev reservation. Keep greetd's configured VT in that set. Normal Artix VT1–6 gettys can remain enabled.

Reload system-bus policy and the relevant device rules before starting:

```sh
sudo udevadm control --reload
sudo udevadm trigger --action=change
sudo udevadm settle

# Enable sessiond and D-Bus
sudo s6 repo sync
sudo s6 enable dbus sessiond
sudo s6 apply

sudo s6 live start sessiond greetd-seat0 multiseatd-seat0
```

After that, you should see greeter on VT7 showing graphical login menu. If you still see the terminal, press `Ctrl+Alt+F7` to switch.

Select the desktop that you need, and log into your account.

**Only** after it's proven to work, enable these services on startup
```sh
sudo s6 enable sessiond greetd-seat0 multiseatd-seat0
sudo s6 apply
```

## 5. Enable the user's D-Bus and audio services

Run these commands **without sudo**:

```sh
s6 --user set enable -p dbus pipewire pipewire-pulse wireplumber
s6 --user apply
s6 --user live status
```

After that, your audio should work.
