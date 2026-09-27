# micropanel persistence contract (A/B images)

This applies to the opt-in A/B image (`--layout=ab`) only. The default
single-slot 8 GB image has a writable root and none of this.

An A/B micropanel is an overlay-root appliance: the root filesystem
(`MP_ROOT_A`/`MP_ROOT_B`, mounted read-only under a tmpfs overlay by
`overlayroot=tmpfs:recurse=0`) and the boot filesystem (`MP_BOOT_A`, mounted
`ro`) are disposable, and every update replaces the inactive slot wholesale.
`/data` (label `MICROPANEL_DATA`, p8) is the only durable local write target.
This document is the inventory of every stateful path the image knows about.

Mechanisms, in one place:

- **Data skeleton** `packages/micropanel-data-skeleton.sh` creates the `/data`
  layout below. The image finalizer runs it on first flash; the factory reset
  runs the same script (`/usr/local/sbin/ab-data-skeleton`) after the wipe, so
  a reset device and a freshly flashed one cannot drift. Seeds come from the
  image: `$AB_SEED_ROOT` (the authored root) at finalize time,
  `/media/root-ro` (the read-only lower root) at reset time, and only into an
  empty destination.
- **Bind mounts** are listed in `packages/micropanel-appliance-hook.d/fstab.binds`
  and appended to `/etc/fstab` by the appliance hook. Each is
  `nofail`, requires `data.mount`, runs after `ab-factory-reset.service` and
  before its consumer; every consumer is in `ab-update.conf`
  `AB_RESET_BEFORE`. If `/data` fails to mount the paths fall back to the
  (empty, volatile) lower-root directories - the device boots, forgetfully.
- **Restore units** copy durable identity into the volatile root early in boot.

## Durable state on `/data`

| `/data` path | Owner / mode | Reaches the system as | Writer and purpose | Seed / reset |
| --- | --- | --- | --- | --- |
| `micropanel/` | pi, `0755` | micropanel's `persistent_data.file_path` is `/data/micropanel/settings.json`; `/home/pi/micropanel/settings.json` is a symlink to it for readers | micropanel daemon: brightness and other settings. It saves by writing `settings.json.tmp` beside the file and renaming, so the configured path itself must be on `/data` (a symlink would be replaced by the rename; a file bind mount refuses it) | Seeded from `share/micropanel/settings.json.default` if the image ships one (today it does not; micropanel starts from defaults) |
| `micropanel-system/` | root, `0700` | - | Update state (`AB_STATE_DIR`: `update-state`, the factory-reset marker) and `machine-id` | Wiped by a reset (a reset device looks freshly flashed) |
| `micropanel-system/machine-id` | root; file `0444` | copied to `/etc/machine-id` and `/var/lib/dbus/machine-id` by `micropanel-machine-id.service` (sysinit, before D-Bus and journal flush; restarts journald) | One identity per flashed device, captured from systemd's random first-boot ID | New identity after a reset |
| `micropanel-system/ssh-host-keys/` | root, `0700` | copied into `/etc/ssh` by `micropanel-ssh-host-keys.service` before `ssh.service` | Host keys, created once; `regenerate_ssh_host_keys` and `sshd-keygen` are masked | New keys after a reset |
| `micropanel-system/var-lib-micropanel/` | root, `0755` | bind → `/var/lib/micropanel` (before `dip-switch-resolution.service`) | `dip-reboot-pending`: the DIP-switch service's reboot-loop guard. It must survive the reboot it triggers, or a persistent mismatch reboots forever | Empty |
| `disp-settings/` | root, `0755` | bind → `/var/lib/disp-settings` (before `disp-settings-dual-display-restore.service`) | `dual-display-mode.json`, restored at boot | Empty |
| `kodi/` | pi, `0755` | bind → `/home/pi/.kodi` (before `micropanel.service`) | kodi user data: database, add-ons, settings, thumbnails and caches | Seeded from the image's authored `/home/pi/.kodi` (the add-ons hook builds it), owned by pi; re-seeded by a reset |
| `disptool-results/` | pi, `0755` | bind → `/home/pi/micropanel/share/disptool/display-test-framework/results` (before `micropanel.service`) | disptool test framework measurement runs | Empty |
| `NetworkManager/system-connections/` | root, `0700` | bind → `/etc/NetworkManager/system-connections` (the engine's own line) | NetworkManager keyfiles: the Network menu's DHCP/static profiles, WiFi | The image's shipped profiles; re-seeded by a reset (`AB_RESET_SEED`) |

`host-key` and DIP-guard directories live under the root-only
`micropanel-system/`, not under the pi-owned `micropanel/`, so the pi account
cannot rename them away.

## Device-owned boot configuration (next step)

The display type chosen by the DIP switches (or the OLED menu's HDMI Timing)
is written by `pi-config-txt.sh`. On an A/B image it will live in
`micropanel-display.txt` at the root of `MP_BOOT_A`, shared by both slots and
included by the release-owned `config.txt`; the kernel-module options derived
from it are regenerated at every boot. That split is not in the image yet;
until it is, a display-type change on an A/B image rewrites `config.txt` and
loses the slot selector. Do not change the display type on an A/B bench image
built before the include split.

## Intentionally volatile

- The root overlay: everything under `/` not listed above, including `/etc`
  (other than the NetworkManager bind), `/var`, `/home/pi` (other than the
  binds and the settings path). `/etc/machine-id`, `/var/lib/dbus/machine-id`
  and `/etc/ssh` host keys are restored copies of `/data` state.
- `/etc/modprobe.d/hh983.conf`, `/etc/modules-load.d/custom-drivers.conf`,
  `/etc/modprobe.d/blacklist-himax-mmi.conf`: derived from the display type;
  regenerated at boot once the include split lands.
- `/tmp/micropanel.log` (the System → Transfer Logs feature copies it to USB),
  FPGA/RH850/Vivado flash logs, hdmi-patch state, ping output, `/run/als-dimmer`
  and the als-dimmer socket: per-boot diagnostics and scratch.
- System journal, apt state, NetworkManager DHCP leases, dnsmasq leases, and the
  time-sync cache. The Pi has no RTC: a factory-reset device boots in the past
  until NTP syncs.
- Swap: none. `dphys-swapfile` is disabled (a swap file on an overlay root is
  RAM), `/var/swap` removed.

## Services changed by the appliance conversion

| Unit | Change | Why |
| --- | --- | --- |
| `micropanel-machine-id.service` | created, enabled (sysinit) | restore durable identity |
| `micropanel-ssh-host-keys.service` | created, enabled (wanted by `ssh.service`) | restore durable host keys |
| `regenerate_ssh_host_keys.service`, `sshd-keygen.service` | disabled, masked | would regenerate keys every boot |
| `dphys-swapfile.service` | disabled | no swap on an overlay root |
| `rpi-eeprom-update.service` | disabled | EEPROM updates are outside the A/B chain |
| `sdm-firstboot.service` | disabled, `ConditionKernelCommandLine=micropanel.sdm-firstboot=1` guard | would rerun (in RAM) every boot |
| `systemd-networkd-wait-online.service` | masked | NetworkManager owns networking |
| `systemd-remount-fs.service`, `systemd-growfs-root.service` | skipped when `overlayroot=` is on the cmdline | an overlay root is neither remountable nor growable |
| `ab-update-commit.service`, `ab-factory-reset.service` | installed by the A/B finalizer | the engine |

Measured on the 01.33 image: cloud-init is not installed (the hook would
silence its key output if it were); `userconfig.service` exists but is not
enabled.
