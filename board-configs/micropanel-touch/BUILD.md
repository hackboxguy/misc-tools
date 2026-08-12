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

Before flashing, inspect the result with a loop device or `fdisk -l`: it must
have boot (`p1`), authored root (`p2`), and the `MICROPANEL_DATA` ext4 data
partition (`p3`). The image must not carry an `expand-root` first-boot action.

On the first hardware boot, verify:

```sh
findmnt -no TARGET,OPTIONS /
findmnt /data
systemctl is-active micropanel-touch.service micropanel-touch-privileged.service
stat -c '%U %a %n' /run/micropanel-touch/broker.sock
```

The expected result is an overlay-backed read-only root, a mounted `/data`,
two active services, and a `0600` broker socket owned by `micropanel-touch`.
Do not test a real IP change until the interface, replacement values, and
recovery path are explicitly chosen.
