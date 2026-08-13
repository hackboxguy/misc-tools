# MicroPanel Touch image build

From the `misc-tools` checkout, build the first Sprint 2.5 appliance slice
with:

```sh
sudo ./build-image.sh --board=micropanel-touch --version=00.10
```

The board config pins both the Raspberry Pi OS Lite artifact and the
`micropanel-touch` commit named in `hooks.txt`. That commit must be available
from its Git remote before starting the build; the dedicated hook clones it
with its LVGL submodule recursively.

The development image uses the build system's standard Pi-user password when
`--password` is omitted. Supply `--password=PASS` to override it. When only
the password or an apps hook changed, retain the completed base image and
rebuild just apps with `--skip-base`.

Before flashing, inspect the result with a loop device or `fdisk -l`: it must
have boot (`p1`), authored root (`p2`), and the `MICROPANEL_DATA` ext4 data
partition (`p3`). The image must not carry an `expand-root` first-boot action.

On the first hardware boot, verify:

```sh
findmnt -no TARGET,OPTIONS /
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /data
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /etc/NetworkManager/system-connections
systemctl is-active micropanel-touch.service micropanel-touch-privileged.service
stat -c '%U %a %n' /run/micropanel-touch/broker.sock
systemctl --failed --no-pager
```

The accepted predecessor has an overlay-backed root, two active services, no
failed units, and a `0600` broker socket owned by `micropanel-touch`. The
follow-up image must show `/data` as `p3` `ext4` (not `overlay` or `tmpfs`),
and the NetworkManager profile directory must resolve to the corresponding
data-backed bind mount. Its root command line must contain
`overlayroot=tmpfs:recurse=0`.

Before treating the image as persistence-ready, perform this harmless
application-data check, then repeat the read after a normal reboot and an
unplug/reapply-power boot:

```sh
sudo sh -c 'printf "%s\\n" persistence-check > /data/micropanel-touch/.persistence-check'
sync
sudo cat /data/micropanel-touch/.persistence-check
sudo sha256sum /etc/ssh/ssh_host_*_key.pub | sort
cat /etc/machine-id
```

Record the SSH public-key hashes and `machine-id` before reboot. The hashes
must remain stable; record whether `machine-id` remains stable too. The image
has a persistent SSH-host-key seed, but `machine-id` has no deliberately
implemented early-boot persistence yet and must not be claimed stable until
observed. A broker-applied NetworkManager change must similarly be checked
after reboot before it is called persistent.

The NetworkManager polkit rule intentionally requires the non-root `pi` account
to use `sudo` for direct mutation; the appliance's intended mutation route is
the typed broker. Do not test a real IP change until the interface, replacement
values, and recovery path are explicitly chosen.
