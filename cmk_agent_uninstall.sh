#!/bin/bash
set -euo pipefail

# Roll back local Checkmk agent setup on Unraid.
# This script is idempotent: it is safe to run multiple times.

REMOVE_XINETD_PACKAGE="false"   # set "true" only if you want to remove xinetd package too
REMOVE_AGENT_USER="true"        # remove cmk-agent user/group if present

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

echo "Stopping/removing Checkmk xinetd service files..."
rm -f /etc/xinetd.d/check-mk-agent /etc/xinetd.d/check_mk

if command -v xinetd >/dev/null 2>&1; then
  # Reload xinetd config by restart.
  killall xinetd >/dev/null 2>&1 || true
  xinetd || true
fi

echo "Removing Checkmk plugin files..."
rm -f /usr/lib/check_mk_agent/plugins/mk_docker.py
rm -f /usr/lib/check_mk_agent/plugins/smart

echo "Removing cmk-agent-ctl binary if present..."
rm -f /usr/bin/cmk-agent-ctl

echo "Removing installed Checkmk agent package(s)..."
for pkg in /var/log/packages/check_mk_agent-* /var/log/packages/check-mk-agent-*; do
  [[ -e "${pkg}" ]] || continue
  removepkg "$(basename "${pkg}")" || true
done

if [[ "${REMOVE_XINETD_PACKAGE}" == "true" ]]; then
  echo "Removing xinetd package(s)..."
  for pkg in /var/log/packages/xinetd-*; do
    [[ -e "${pkg}" ]] || continue
    removepkg "$(basename "${pkg}")" || true
  done
fi

echo "Removing runtime/config leftovers..."
rm -rf /var/lib/cmk-agent
rm -rf /var/lib/check_mk_agent
rm -rf /etc/check_mk

if [[ "${REMOVE_AGENT_USER}" == "true" ]]; then
  echo "Removing cmk-agent user/group..."
  userdel cmk-agent >/dev/null 2>&1 || true
  groupdel cmk-agent >/dev/null 2>&1 || true
fi

echo "Rollback complete."
