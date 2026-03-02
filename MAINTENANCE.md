# Checkmk on Unraid: Maintenance Notes

This folder contains two operational scripts:

- `cmk_agent_install.sh`
- `cmk_agent_uninstall.sh`

Goal: install and maintain Checkmk Linux agent on Unraid (Slackware-based, ramdisk rootfs) with reliable reboot behavior.

## Why this is custom

Unraid is not Debian-based, so `check-mk-agent_*.deb` cannot be installed directly with `dpkg/apt`.
The install script converts the `.deb` payload into a Slackware package (`.tgz`) and installs it with `upgradepkg`.

Also, Unraid root filesystem is ephemeral; required service files must be recreated at startup.

## What `cmk_agent_install.sh` does

1. Waits until Checkmk agent `.deb` endpoint is reachable.
2. Downloads the `.deb` from `CHECK_MK_SERVER_URL`.
3. Extracts Debian archive (`ar` or `bsdtar` fallback).
4. Extracts payload archive (`data.tar`, `.gz`, `.xz`, `.bz2`, `.zst` supported).
5. Removes Debian/systemd-only parts not needed for Unraid.
6. Builds Slackware package with `makepkg` and installs via `upgradepkg`.
7. Ensures `xinetd` is installed (local package at `/boot/packages/...txz`).
8. Runs upstream-style postinstall hooks from `/var/lib/cmk-agent/scripts/*` as available.
9. Ensures `cmk-agent-ctl` binary exists (unzips from `/var/lib/cmk-agent/cmk-agent-ctl.gz` if needed).
10. Ensures `cmk-agent` system user/home exists.
11. Ensures xinetd service file exists, enabled, and restarted.
12. Enforces optional source restriction via `ONLY_FROM_IPS` in `/etc/xinetd.d/check-mk-agent`.
13. Installs optional plugins (`mk_docker.py`, `smart`) from Checkmk server.

## What `cmk_agent_uninstall.sh` does

- Removes Checkmk xinetd service files.
- Restarts xinetd config.
- Removes Checkmk plugins and `cmk-agent-ctl` binary.
- Removes installed Checkmk package entries.
- Cleans runtime/config leftovers.
- Optionally removes `cmk-agent` user/group.
- Optionally removes `xinetd` package (controlled by script flags).

## Key operational decisions and discoveries

- **Controller registration (`cmk-agent-ctl register`) is not the primary path here.**
  - On Unraid/xinetd legacy mode, `/run/check-mk-agent.socket` is not active as in full controller-managed mode.
  - Expected: `cmk-agent-ctl` may show socket inoperational while legacy TCP pull still works.
- **Legacy mode requires xinetd + service file.**
  - Problem observed: xinetd installed but no `/etc/xinetd.d/check-mk-agent` => no listener on 6556.
  - Fix: always create/migrate service file from `/etc/check_mk/xinetd-service-template.cfg`.
- `**cmk-agent-ctl` and `cmk-agent` user are not guaranteed by naive repackaging.**
  - Debian maintainer scripts normally handle this; custom conversion must do it explicitly.
- **Access control should be explicit.**
  - `ONLY_FROM_IPS` is used to set `only_from` in xinetd service.
  - This is the main network hardening mechanism for legacy mode.

## Expected healthy state (legacy mode)

- `check_mk_agent` exists and returns data.
- `xinetd` running and listening on `*:6556`.
- `/etc/xinetd.d/check-mk-agent` exists with:
  - `disable = no`
  - `only_from = <Checkmk server IP(s)>` (if configured)
- Checkmk server can poll port 6556 successfully.

## Update checklist (future)

When bumping Checkmk agent version:

1. Update `CHECK_MK_AGENT_VERSION` in `cmk_agent_install.sh`.
2. Verify `.deb` URL path still matches server layout.
3. Re-test payload extraction format support (especially `data.tar.`* variant).
4. Re-run install on test host and validate:
  - listener on 6556
  - plugin install
  - reboot persistence
5. Re-run uninstall and verify rollback leaves expected state.

When changing xinetd package source:

1. Update `XINETD_LOCAL_PACKAGE`.
2. Validate installation path still works with `upgradepkg --install-new`.
3. Confirm service starts and binds 6556.

## Quick troubleshooting

- No listener on 6556:
  - check `xinetd` exists/runs
  - check `/etc/xinetd.d/check-mk-agent` exists and `disable = no`
  - restart `xinetd`
- `cmk-agent-ctl register` fails on socket:
  - expected in legacy xinetd deployment
  - use legacy polling in Checkmk instead of controller registration
- External host can connect unexpectedly:
  - check `only_from` and network ACL/firewall segmentation

