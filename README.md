# Quarantine for Asuswrt-Merlin

Unknown devices automatically land in a restricted "quarantine" subnet. Devices you know (DHCP reservations) stay on your normal LAN. Manage everything from a tab in the router GUI.

> **This is not a security boundary.** It is a convenience layer on top of DHCP and firewall rules. See [Limitations](#limitations).

Developed and tested on an RT-AX88U with Asuswrt-Merlin 3004.388.13_alpha1. It may work on other Merlin routers, but that is untested.

## How it works

1. dnsmasq hands out LAN addresses only to MAC addresses that have a DHCP reservation (YazDHCP or the native Asuswrt reservations). Everyone else gets an address in a separate /24 (the quarantine subnet, chosen automatically next to your LAN).
2. iptables chains restrict what the quarantine subnet may reach: the router itself and all private ranges are blocked, and only the ports of the selected access mode are allowed to the internet.
3. In the GUI you can **Trust** a device (creates a normal DHCP reservation and moves the device to the LAN), **Block** it (drops all its traffic by MAC address) or clear the quarantine list.

## Features

- On / Off switch; Off gives you your normal network back
- Access modes for quarantined devices:
  - **Basic** - DNS (53), HTTP (80), HTTPS (443)
  - **Extended** (default) - Basic + NTP (udp 123) + QUIC (udp 443)
  - **Custom** - Extended + your own ports (up to 20, `443, 8883, 123/udp`)
  - **Open** - no port restriction (private ranges and the router stay blocked)
- Trust / Block / Unblock per device; blocked devices are listed separately and survive Clear
- Optional mail notification for new devices (uses your existing amtm mail setup, see below)
- Built-in diagnostics and self-test, debug log, install with backup and automatic rollback

## Requirements

- Asuswrt-Merlin with JFFS custom scripts enabled, SSH access, a USB disk mounted at `/tmp/mnt/sda1`
- LAN with a /24 netmask
- At least one DHCP reservation (YazDHCP or native) - the quarantine refuses to turn on without known devices, otherwise every device would be quarantined
- Optional, for mail: amtm with mail configured (Settings > email)

## Install

### Option 1: direct from the GitHub release (one command)

Run this over SSH on the router. It downloads the installer, verifies its SHA256 checksum and only runs it when the checksum matches:

```
[ -w /tmp/mnt/sda1 ] || echo "NO WRITE PERMISSION on /tmp/mnt/sda1"; /usr/sbin/curl -fsSL -o /tmp/mnt/sda1/quarantine-setup-0.18.sh https://github.com/SnbReef2009/quarantine-merlin/releases/download/v0.18/quarantine-setup-0.18.sh && [ "$(/usr/sbin/openssl dgst -sha256 /tmp/mnt/sda1/quarantine-setup-0.18.sh | awk '{print $NF}')" = "056faa3ec8f49128b274358304da303777be1f033b99260f022f81d766b391a9" ] && sh /tmp/mnt/sda1/quarantine-setup-0.18.sh || echo "DOWNLOAD OR CHECKSUM FAILED - script not run"
```

The checksum is part of the command, so a corrupted or modified download is never executed. Note that the checksum lives in this repository too: it protects against a damaged download, not against a compromised repository. If you want to be sure, read the script first (it is a plain shell script).

### Option 2: manual

1. Download `quarantine-setup-0.18.sh` from the [Releases](../../releases) page and copy it to `/tmp/mnt/sda1/` on the router.
2. Check the checksum and compare it with `SHA256SUMS`:

```
/usr/sbin/openssl dgst -sha256 /tmp/mnt/sda1/quarantine-setup-0.18.sh
```

3. Run it:

```
sh /tmp/mnt/sda1/quarantine-setup-0.18.sh
```

The installer backs up everything it touches, installs, runs a self-test and rolls back automatically if the self-test fails. Open the router GUI in a private window afterwards; the tab **Quarantine** is added to the menu.

## Uninstall (no traces)

```
sh /jffs/addons/quarantine.d/cli.sh uninstall
```

Type `YES` to confirm. This removes the hooks in `/jffs/scripts`, the cron job, the menu tab, the GUI page, all firewall chains, the quarantine gateway address, every `qt_*` setting, the block list, debug logs and install backups, and restarts dnsmasq. A safety copy of your hook files and settings is written to `/tmp` (RAM only, gone after a reboot).

Not removed: DHCP reservations (they are ordinary reservations you may want to keep) and your own copy of the setup script.

## Mail notifications and credentials

Quarantine has **no mail credentials of its own**. When notifications are on, it reads the SMTP settings and the encrypted password from your existing amtm mail setup (`/jffs/addons/amtm/mail/`) and decrypts it the same way amtm does, at the moment a mail is sent. Nothing is stored or created by this add-on. If amtm mail is not configured, notifications simply stay off and the diagnostics say so.

## Command line

```
sh /jffs/addons/quarantine.d/cli.sh status | selftest | diag | uninstall
```

## Limitations

- **Never spoofing-resistant.** Anyone who copies the MAC address of a known device is treated as that device.
- **A static IP on the LAN range keeps the device on the LAN.** Detection is lease based: a device that never asks DHCP for an address is not seen.
- IPv4 only. IPv6 is not handled.
- No VLANs and no isolation on layer 2. This is firewall blocking only; there is no VPN routing for the quarantine subnet.
- Modifies dnsmasq configuration (via `dnsmasq.postconf`), firewall rules and the router GUI. Use at your own risk and keep a backup of your router configuration.

## License

MIT, see [LICENSE](LICENSE).
