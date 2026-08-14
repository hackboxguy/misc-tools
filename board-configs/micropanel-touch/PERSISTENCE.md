# MicroPanel Touch persistence contract

`micropanel-touch` is an overlay-root appliance. Its root filesystem and boot
filesystem are deliberately disposable; `/data` is the only durable local
write target and is the direct `MICROPANEL_DATA` ext4 partition. This document
is the release inventory for every stateful path in the board image.

## Durable state on `/data`

| Path | Owner / mode | Writer and purpose | Durability rule |
| --- | --- | --- | --- |
| `/data/micropanel-touch/` | `micropanel-touch`, `0750` | HMI configuration and application state | Individual settings writers use atomic replace; unavailable data causes an in-memory fallback, never a write to the overlay root. |
| `micropanel-touch/touch-calibration.conf` | HMI account | Saved residual touch calibration | Atomic replacement; a mismatched panel/range is ignored. |
| `micropanel-touch/display-settings.conf` | HMI account | Auto-standby enabled flag and timeout | Atomic replacement after the user presses Apply. |
| `micropanel-touch/display-brightness.conf` | HMI account | Luckfox display brightness percentage | Atomic replacement as the slider changes. |
| `micropanel-touch/screen-lock.conf` | HMI account, `0600` | Salted PBKDF2 PIN verifier and enabled state | Atomic replacement; no plaintext PIN is written. Forgotten PIN recovery is reimaging the card. |
| `micropanel-touch/logs/` | HMI account | Action/application logs | Best-effort diagnostics only; never stores secrets. |
| `micropanel-touch/ssh-host-keys/` | root, `0700` | Persistent SSH host private/public keys | The early key service validates or creates keys, then copies them into volatile `/etc/ssh` before `sshd`. |
| `/data/micropanel-touch-system/machine-id` | root, `0700` directory; file `0444` | One identity per flashed appliance | An early root service captures systemd's random first-boot ID with atomic replace and fsync, then restores it before D-Bus, NetworkManager, SSH, and the HMI start. |
| `/data/NetworkManager/system-connections/` | root, `0700` | NetworkManager DHCP/static connection keyfiles | Bind-mounted at the normal `/etc/NetworkManager/system-connections` path. |
| `/data/micropanel-touch-network/dhcp-server/` | root with HMI group read access, `0750` | Broker-owned dnsmasq server configuration | The privileged handler writes validated configuration; DHCP leases themselves are intentionally volatile. |

The image finalizer creates all root-owned paths. The machine-ID service also
creates its own directory after proving that `/data` is the actual mounted
partition, so an in-place software upgrade can safely add this state to an
older data volume.

## Intentionally volatile state

- The root overlay, including `/etc` other than the NetworkManager bind mount.
  `/etc/machine-id`, `/var/lib/dbus/machine-id`, and `/etc/ssh` are restored
  runtime copies of the durable state above.
- `/run/micropanel-touch/` and the broker socket; it is recreated with its
  service on every boot.
- System journal, package-manager state, cloud-init state, temporary files,
  NetworkManager DHCP lease database, dnsmasq leases, and the system time-sync
  cache (the Pi has no assumed durable RTC).
- Kernel backlight state, framebuffer/DRM state, and the running application
  process.
- Removable-media mount state and USB-export bookkeeping. The appliance has no
  automatic persistent USB metadata writer; a future USB feature must add its
  destination to this inventory before it writes.

## Prohibited writes and degradation behaviour

No HMI or handler may treat `/boot/firmware`, the lower root image, or an
arbitrary path below `/` as durable state. The persistent data mount is
`nofail` so a damaged or absent p3 does not prevent boot. In that case the HMI
uses its documented in-memory defaults, the system identity remains the random
systemd transient identity for that boot (never the build machine's ID), and
the lower-image SSH keys are only a recovery fallback. Such a boot is not
fleet-secure and must be repaired or reimaged before deployment.

Before release, test every durable entry across both `reboot` and full power
removal. The image build guide contains the machine-identity and general
persistence acceptance commands.
