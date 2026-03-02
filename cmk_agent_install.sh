#!/bin/bash
set -euo pipefail

# -----------------------------
# Configuration
# -----------------------------
CHECK_MK_SERVER_URL="http://<CHECKMK_SERVER_IP>/<CHECKMK_SITE>/"
CHECK_MK_AGENT_VERSION="2.4.0p22-1"
XINETD_LOCAL_PACKAGE="/boot/packages/xinetd-2.3.15.4-x86_64-1_slonly.txz"
ONLY_FROM_IPS="${ONLY_FROM_IPS:-<CHECKMK_SERVER_IP>}" # space-separated list, empty disables restriction

PLUGIN_DIR="/usr/lib/check_mk_agent/plugins"
WAIT_TIME=5          # seconds
TIMEOUT=300          # seconds
START_TIME=$(date +%s)

# Derived URLs/paths
BASE_URL="${CHECK_MK_SERVER_URL%/}"
DOCKER_PLUGIN_URL="${BASE_URL}/check_mk/agents/plugins/mk_docker.py"
SMART_PLUGIN_URL="${BASE_URL}/check_mk/agents/plugins/smart"
AGENT_DEB_URL="${BASE_URL}/check_mk/agents/check-mk-agent_${CHECK_MK_AGENT_VERSION}_all.deb"

WORK_DIR="/tmp/checkmk-agent-build"
DEB_DIR="${WORK_DIR}/deb"
EXTRACT_DIR="${WORK_DIR}/extracted"
PKG_DIR="${WORK_DIR}/pkg"
PKG_PATH="${PKG_DIR}/check_mk_agent-${CHECK_MK_AGENT_VERSION}.tgz"
TMP_DOCKER_PLUGIN="/tmp/mk_docker.py.$$"
TMP_SMART_PLUGIN="/tmp/smart.$$"

cleanup() {
  rm -f "${TMP_DOCKER_PLUGIN}" "${TMP_SMART_PLUGIN}"
  if [[ -n "${WORK_DIR:-}" && "${WORK_DIR}" == /tmp/checkmk-agent-build* ]]; then
    rm -rf "${WORK_DIR}"
  fi
}
trap cleanup EXIT

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}"
    exit 1
  fi
}

require_any_cmd() {
  local first="$1"
  local second="$2"
  if command -v "${first}" >/dev/null 2>&1 || command -v "${second}" >/dev/null 2>&1; then
    return
  fi
  echo "Missing required command: ${first} (or ${second} as fallback)"
  exit 1
}

extract_deb_archive() {
  local deb_path="$1"
  local out_dir="$2"

  if command -v ar >/dev/null 2>&1; then
    (
      cd "${out_dir}"
      ar x "${deb_path}"
    )
    return
  fi

  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xf "${deb_path}" -C "${out_dir}"
    return
  fi

  echo "Missing required command: ar (or bsdtar as fallback)"
  exit 1
}

download_file() {
  local url="$1"
  local out="$2"
  local curl_args=(--insecure --fail --show-error --silent --location --output "${out}")
  curl "${curl_args[@]}" "${url}"
}

http_code() {
  local url="$1"
  local curl_args=(--insecure --write-out '%{http_code}' --silent --output /dev/null)
  curl "${curl_args[@]}" "${url}" || true
}

install_python_docker_dep() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip install docker >/dev/null 2>&1 || true
  elif command -v pip3 >/dev/null 2>&1; then
    pip3 install docker >/dev/null 2>&1 || true
  elif command -v pip >/dev/null 2>&1; then
    pip install docker >/dev/null 2>&1 || true
  fi
}

ensure_cmk_agent_ctl() {
  if command -v cmk-agent-ctl >/dev/null 2>&1; then
    return 0
  fi

  if [[ -f "/var/lib/cmk-agent/cmk-agent-ctl.gz" ]]; then
    gzip -dc "/var/lib/cmk-agent/cmk-agent-ctl.gz" > "/usr/bin/cmk-agent-ctl"
    chmod 755 "/usr/bin/cmk-agent-ctl"
    echo "Installed /usr/bin/cmk-agent-ctl from packaged archive."
    return 0
  fi

  echo "Warning: cmk-agent-ctl not found and no /var/lib/cmk-agent/cmk-agent-ctl.gz available."
}

ensure_cmk_agent_user() {
  local agent_user="cmk-agent"
  local home_dir="/var/lib/cmk-agent"
  local usershell="/bin/false"

  if [[ -x /sbin/nologin ]]; then
    usershell="/sbin/nologin"
  elif [[ -x /usr/sbin/nologin ]]; then
    usershell="/usr/sbin/nologin"
  elif [[ -x /bin/nologin ]]; then
    usershell="/bin/nologin"
  fi

  if ! id "${agent_user}" >/dev/null 2>&1; then
    echo "Creating ${agent_user} system user..."
    useradd \
      --comment "Checkmk agent system user" \
      --system \
      --home-dir "${home_dir}" \
      --no-create-home \
      --user-group \
      --shell "${usershell}" \
      "${agent_user}"
  fi

  mkdir -p "${home_dir}"
  chown -R "${agent_user}:${agent_user}" "${home_dir}"
}

ensure_xinetd() {
  if command -v xinetd >/dev/null 2>&1; then
    return 0
  fi

  if [[ -f "${XINETD_LOCAL_PACKAGE}" ]]; then
    echo "xinetd missing, installing local package: ${XINETD_LOCAL_PACKAGE}"
    upgradepkg --install-new "${XINETD_LOCAL_PACKAGE}" || true
  fi

  if command -v xinetd >/dev/null 2>&1; then
    return 0
  fi

  echo "Warning: xinetd is still not available."
  echo "Warning: agent socket may remain inoperational until xinetd is installed."
  return 1
}

ensure_xinetd_service() {
  local template="/etc/check_mk/xinetd-service-template.cfg"
  local target="/etc/xinetd.d/check-mk-agent"
  local legacy_target="/etc/xinetd.d/check_mk"

  if ! command -v xinetd >/dev/null 2>&1; then
    return 0
  fi

  mkdir -p /etc/xinetd.d

  # Prefer modern service name; migrate legacy filename when needed.
  if [[ -f "${legacy_target}" && ! -f "${target}" ]]; then
    cp "${legacy_target}" "${target}"
  fi

  if [[ ! -f "${target}" && -f "${template}" ]]; then
    cp "${template}" "${target}"
  fi

  if [[ -f "${target}" ]]; then
    # Force enabled service to avoid stale "disable = yes" configs.
    if grep -q '^[[:space:]]*disable[[:space:]]*=' "${target}" 2>/dev/null; then
      sed -i 's/^[[:space:]]*disable[[:space:]]*=.*/    disable        = no/' "${target}" || true
    else
      printf '\n    disable        = no\n' >> "${target}"
    fi

    # Restrict who may query the agent when ONLY_FROM_IPS is set.
    if [[ -n "${ONLY_FROM_IPS}" ]]; then
      if grep -q '^[[:space:]]*only_from[[:space:]]*=' "${target}" 2>/dev/null; then
        sed -i "s|^[[:space:]]*only_from[[:space:]]*=.*|    only_from      = ${ONLY_FROM_IPS}|" "${target}" || true
      elif grep -q '^[[:space:]]*#only_from[[:space:]]*=' "${target}" 2>/dev/null; then
        sed -i "s|^[[:space:]]*#only_from[[:space:]]*=.*|    only_from      = ${ONLY_FROM_IPS}|" "${target}" || true
      else
        printf '    only_from      = %s\n' "${ONLY_FROM_IPS}" >> "${target}"
      fi
    fi
  else
    echo "Warning: no xinetd service file found or created."
    return 1
  fi

  killall xinetd >/dev/null 2>&1 || true
  xinetd
}

run_cmk_postinstall_hooks() {
  local base="/var/lib/cmk-agent/scripts"
  local deployed=""

  if [[ -x "${base}/migrate.sh" || -f "${base}/migrate.sh" ]]; then
    /bin/sh "${base}/migrate.sh" || true
  fi

  if [[ -x "${base}/super-server/setup" || -f "${base}/super-server/setup" ]]; then
    /bin/sh "${base}/super-server/setup" cleanup || true
    BIN_DIR="/usr/bin" /bin/sh "${base}/super-server/setup" deploy || true
    if /bin/sh "${base}/super-server/setup" getdeployed >/dev/null 2>&1; then
      deployed="$(/bin/sh "${base}/super-server/setup" getdeployed 2>/dev/null || true)"
    fi
  fi

  if [[ -x "${base}/manage-agent-user.sh" || -f "${base}/manage-agent-user.sh" ]]; then
    BIN_DIR="/usr/bin" /bin/sh "${base}/manage-agent-user.sh" || true
  fi

  if [[ -x "${base}/super-server/setup" || -f "${base}/super-server/setup" ]]; then
    /bin/sh "${base}/super-server/setup" trigger || true
  fi

  if [[ -x "${base}/manage-binaries.sh" || -f "${base}/manage-binaries.sh" ]]; then
    /bin/sh "${base}/manage-binaries.sh" install || true
  fi

  if [[ -z "${deployed}" ]]; then
    echo "Warning: no agent super-server deployed (no systemd/xinetd setup active)."
    echo "Warning: cmk-agent-ctl may report 'Agent socket: inoperational' until a super-server is available."
  else
    echo "Deployed Checkmk super-server backend: ${deployed}"
  fi
}

echo "Checkmk URL: ${BASE_URL}"
echo "Agent .deb:  ${AGENT_DEB_URL}"

# -----------------------------
# Dependencies for mk_docker + package conversion
# -----------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (Unraid User Scripts normally runs as root)."
  exit 1
fi

require_cmd curl
require_cmd tar
require_cmd makepkg
require_cmd upgradepkg
require_any_cmd ar bsdtar

# -----------------------------
# Wait until required Checkmk agent .deb is reachable
# -----------------------------
while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))

  if [[ $ELAPSED_TIME -ge $TIMEOUT ]]; then
    echo "Timeout reached. Checkmk server is not available."
    exit 1
  fi

  deb_probe_response="$(http_code "${AGENT_DEB_URL}")"
  if [[ "${deb_probe_response}" == "200" ]]; then
    echo "Checkmk agent package endpoint is online (deb=${deb_probe_response})"
    break
  fi

  echo "Checkmk agent package unavailable (deb=${deb_probe_response:-n/a}), retrying in ${WAIT_TIME}s..."
  sleep "${WAIT_TIME}"
done

# Install Python dependency only after Checkmk endpoint is confirmed reachable.
install_python_docker_dep

# -----------------------------
# Build and install Slackware package from local .deb
# -----------------------------
deb_response="$(http_code "${AGENT_DEB_URL}")"
if [[ "$deb_response" == "200" ]]; then
  echo "Agent .deb is reachable, building Slackware package..."

  # Optional helper: install conversion tools only when .deb path is usable.
  if command -v slackpkg >/dev/null 2>&1; then
    slackpkg -batch=on -default_answer=y install flex binutils || true
  fi

  WORK_DIR="$(mktemp -d /tmp/checkmk-agent-build.XXXXXX)"
  DEB_DIR="${WORK_DIR}/deb"
  EXTRACT_DIR="${WORK_DIR}/extracted"
  PKG_DIR="${WORK_DIR}/pkg"
  PKG_PATH="${PKG_DIR}/check_mk_agent-${CHECK_MK_AGENT_VERSION}.tgz"
  mkdir -p "${DEB_DIR}" "${EXTRACT_DIR}" "${PKG_DIR}"

  download_file "${AGENT_DEB_URL}" "${DEB_DIR}/check-mk-agent.deb"

  extract_deb_archive "${DEB_DIR}/check-mk-agent.deb" "${DEB_DIR}"

  # Detect common Debian payload archives (plain/gz/xz/bz2/zst).
  data_archive=""
  for candidate in data.tar data.tar.gz data.tar.xz data.tar.bz2 data.tar.zst; do
    if [[ -f "${DEB_DIR}/${candidate}" ]]; then
      data_archive="${DEB_DIR}/${candidate}"
      break
    fi
  done

  if [[ -z "${data_archive}" ]]; then
    echo "Unsupported .deb payload format: no data.tar* archive found."
    exit 1
  fi

  if [[ "${data_archive}" == "${DEB_DIR}/data.tar.zst" ]]; then
    if tar --zstd -C "${EXTRACT_DIR}" -xvf "${data_archive}" 2>/dev/null; then
      :
    elif command -v zstd >/dev/null 2>&1; then
      zstd -dc "${data_archive}" | tar -C "${EXTRACT_DIR}" -xvf -
    else
      echo "data.tar.zst found but tar --zstd/zstd is unavailable."
      exit 1
    fi
  else
    tar -C "${EXTRACT_DIR}" -xvf "${data_archive}"
  fi

  # remove Debian/systemd-specific bits, keep agent content
  rm -rf \
    "${EXTRACT_DIR}/etc/systemd" \
    "${EXTRACT_DIR}/usr/lib/check_mk_agent/plugins" \
    "${EXTRACT_DIR}/usr/share/doc/check-mk-agent/changelog.Debian.gz"

  cd "${EXTRACT_DIR}"
  makepkg -l y -c y "${PKG_PATH}"

  upgradepkg --install-new "${PKG_PATH}"
  ensure_xinetd || true
  run_cmk_postinstall_hooks
  ensure_cmk_agent_ctl
  ensure_cmk_agent_user
  ensure_xinetd_service || true
  echo "Installed ${PKG_PATH}"
else
  echo "Agent .deb not reachable (HTTP ${deb_response:-n/a}), skipping package build/install."
fi

# -----------------------------
# Install Checkmk docker + smart plugins
# -----------------------------
rm -rf "${PLUGIN_DIR}"
mkdir -p "${PLUGIN_DIR}"
cd "${PLUGIN_DIR}"

download_file "${DOCKER_PLUGIN_URL}" "${TMP_DOCKER_PLUGIN}"
chmod 755 "${TMP_DOCKER_PLUGIN}"
mv "${TMP_DOCKER_PLUGIN}" mk_docker.py

download_file "${SMART_PLUGIN_URL}" "${TMP_SMART_PLUGIN}"
chmod 755 "${TMP_SMART_PLUGIN}"
mv "${TMP_SMART_PLUGIN}" smart

ensure_xinetd_service || true

echo "Done."