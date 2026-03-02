# Unraid Checkmk Agent Scripts

Small helper scripts to install and remove Checkmk agent on Unraid (legacy xinetd mode).

## Files

- `cmk_agent_install.sh`  
  Installs/updates Checkmk agent from your local Checkmk server `.deb`, prepares xinetd listener on port `6556`, and installs optional plugins.

- `cmk_agent_uninstall.sh`  
  Rolls back the setup (service files, binaries, package entries, and runtime leftovers).

## Quick usage

Run on Unraid as root (recommended from User Scripts at Array Start):

```bash
/boot/config/plugins/user.scripts/scripts/Install_CheckMK_Agent/cmk_agent_install.sh
```

Rollback:

```bash
/boot/config/plugins/user.scripts/scripts/Install_CheckMK_Agent/cmk_agent_uninstall.sh
```

## xinetd package location

The install script expects the xinetd package at:

`/boot/packages/xinetd-2.3.15.4-x86_64-1_slonly.txz`

This package can be taken from the original plugin repository package set.

## Notes

- This setup intentionally uses the agent package hosted by the local Checkmk server.
- Legacy xinetd mode is used (TCP pull on `6556`), not full controller-managed registration mode.

## Credits / basis

Based on work from:

- Donimax Unraid Checkmk plugin repository:  
  https://github.com/Donimax/unraid-check-mk-agent
- Current plugin definition used as reference:  
  https://raw.githubusercontent.com/Donimax/unraid-check-mk-agent/refs/heads/master/check_mk_agent24.plg

For implementation details and maintenance guidance, see `MAINTENANCE.md`.
