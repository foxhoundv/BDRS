#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/generated"
mkdir -p "${OUTPUT_DIR}"

# shellcheck disable=SC2034
YW='\033[33m'
# shellcheck disable=SC2034
GN='\033[1;92m'
# shellcheck disable=SC2034
RD='\033[01;31m'
# shellcheck disable=SC2034
BL='\033[36m'
# shellcheck disable=SC2034
CL='\033[m'

header_info() {
  clear
  echo -e "${BL}"
  cat <<'EOF'
 ______  ______   ______ _______
 |_____] |     \ |_____/ |______
 |_____] |_____/ |    \_ ______|
                                
EOF
  echo -e "${CL}Broadcast Distribution RTA System - Proxmox Bootstrap"
  echo -e "${YW}This wizard collects first-run answers and generates Proxmox config templates.${CL}"
  echo
}

section() {
  local title="$1"
  echo
  echo -e "${GN}== ${title} ==${CL}"
}

msg_ok() {
  echo -e "${GN}[OK]${CL} $1"
}

msg_warn() {
  echo -e "${YW}[WARN]${CL} $1"
}

msg_error() {
  echo -e "${RD}[ERROR]${CL} $1"
}

list_usb_candidates() {
  if ! command -v lsusb >/dev/null 2>&1; then
    msg_warn "lsusb not found. Install usbutils to enable USB auto-detection."
    return 1
  fi

  mapfile -t USB_LINES < <(lsusb 2>/dev/null || true)
  if [[ ${#USB_LINES[@]} -eq 0 ]]; then
    msg_warn "No USB devices detected by lsusb."
    return 1
  fi

  USB_IDS=()
  USB_LABELS=()

  local line
  local id
  local label
  for line in "${USB_LINES[@]}"; do
    if [[ "${line}" =~ ID[[:space:]]([0-9a-fA-F]{4}:[0-9a-fA-F]{4})[[:space:]](.*)$ ]]; then
      id="${BASH_REMATCH[1],,}"
      label="${BASH_REMATCH[2]}"
      USB_IDS+=("${id}")
      USB_LABELS+=("${label}")
    fi
  done

  if [[ ${#USB_IDS[@]} -eq 0 ]]; then
    msg_warn "USB devices were listed, but no vendor:product IDs were parsed."
    return 1
  fi

  return 0
}

pick_usb_vendor_product() {
  local default_id="$1"
  local required_profile="${2:-any}"
  local chosen="${default_id}"
  PICKED_USB_ID="${default_id}"

  if ! list_usb_candidates; then
    PICKED_USB_ID="${chosen}"
    return 0
  fi

  echo
  echo -e "${BL}Detected USB Devices${CL}"
  local i
  for i in "${!USB_IDS[@]}"; do
    printf "%2d) %s  %s\n" "$((i + 1))" "${USB_IDS[i]}" "${USB_LABELS[i]}"
  done
  echo " 0) Enter manually / skip"

  while true; do
    local pick
    read -r -p "Select USB device number for audio source [0]: " pick
    if [[ -z "${pick}" ]]; then
      pick="0"
    fi
    if [[ "${pick}" =~ ^[0-9]+$ ]]; then
      if [[ "${pick}" == "0" ]]; then
        PICKED_USB_ID="${chosen}"
        return 0
      fi
      if (( pick >= 1 && pick <= ${#USB_IDS[@]} )); then
        local selected_label="${USB_LABELS[pick-1]}"
        local selected_label_lc="${selected_label,,}"

        if [[ "${required_profile}" == "wing" ]]; then
          if [[ "${selected_label_lc}" != *"wing"* && "${selected_label_lc}" != *"behringer"* ]]; then
            msg_error "No Wing device found on USB selection ${pick}! Please choose a different one."
            continue
          fi
        fi

        chosen="${USB_IDS[pick-1]}"
        msg_ok "Selected USB ID ${chosen}"
        PICKED_USB_ID="${chosen}"
        return 0
      fi
    fi
    msg_error "Invalid selection. Choose 0-${#USB_IDS[@]}."
  done
}

ask_input() {
  local key="$1"
  local question="$2"
  local default="$3"
  local value
  while true; do
    read -r -p "${question} [${default}]: " value
    if [[ -z "${value}" ]]; then
      value="${default}"
    fi
    if [[ -n "${value}" ]]; then
      break
    fi
  done
  printf -v "${key}" '%s' "${value}"
}

ask_bool() {
  local key="$1"
  local question="$2"
  local default="$3"
  local value
  while true; do
    read -r -p "${question} [${default}] (yes/no): " value
    value="${value,,}"
    if [[ -z "${value}" ]]; then
      value="${default}"
    fi
    case "${value}" in
      y|yes|true|1)
        value="true"
        break
        ;;
      n|no|false|0)
        value="false"
        break
        ;;
      *)
        msg_error "Invalid input for ${key}. Use yes or no."
        ;;
    esac
  done
  printf -v "${key}" '%s' "${value}"
}

ask_secret_confirm() {
  local key="$1"
  local question="$2"
  local first
  local second

  while true; do
    read -r -s -p "${question}: " first
    echo
    if [[ -z "${first}" ]]; then
      msg_error "Password cannot be empty."
      continue
    fi

    read -r -s -p "Confirm ${question,,}: " second
    echo

    if [[ "${first}" != "${second}" ]]; then
      msg_error "Passwords do not match. Please try again."
      continue
    fi

    printf -v "${key}" '%s' "${first}"
    return 0
  done
}

ask_choice() {
  local key="$1"
  local question="$2"
  local default="$3"
  shift 3
  local allowed=("$@")
  local value

  while true; do
    read -r -p "${question} [${default}]: " value
    value="${value,,}"
    if [[ -z "${value}" ]]; then
      value="${default}"
    fi
    for candidate in "${allowed[@]}"; do
      if [[ "${value}" == "${candidate}" ]]; then
        printf -v "${key}" '%s' "${value}"
        return 0
      fi
    done
    msg_error "Invalid option. Allowed: ${allowed[*]}"
  done
}

ensure_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    msg_error "Required command not found: ${cmd}"
    exit 1
  fi
}

assert_unused_ids() {
  local id="$1"
  local label="$2"

  if pct config "${id}" >/dev/null 2>&1; then
    msg_error "${label} VMID ${id} already exists as an LXC container."
    exit 1
  fi

  if qm config "${id}" >/dev/null 2>&1; then
    msg_error "${label} VMID ${id} already exists as a VM."
    exit 1
  fi
}

apply_generated_resources() {
  section "Applying Generated Resources"

  ensure_command pct
  ensure_command qm

  assert_unused_ids "${VMID_AUDIO}" "Audio Engine"
  assert_unused_ids "${VMID_CONTROL}" "Control Plane"
  assert_unused_ids "${VMID_RECORDING}" "Recording"

  msg_ok "Creating audio-engine LXC (${VMID_AUDIO})"
  pct create "${VMID_AUDIO}" "${TEMPLATE_PATH}" \
    --hostname audio-engine \
    --storage "${STORAGE_AUDIO}" \
    --rootfs "${STORAGE_AUDIO}:${AUDIO_ROOTFS}" \
    --memory "${AUDIO_MEM}" \
    --cores "${AUDIO_CORES}" \
    --password "${LXC_ROOT_PASSWORD}" \
    --swap 0 \
    --net0 "${AUDIO_NET_SPEC}" \
    --unprivileged 0 \
    --features nesting=1 \
    --onboot 1 \
    --startup order=2,up=10

  cat >> "/etc/pve/lxc/${VMID_AUDIO}.conf" <<EOF
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir
EOF

  msg_ok "Creating control-plane LXC (${VMID_CONTROL})"
  pct create "${VMID_CONTROL}" "${TEMPLATE_PATH}" \
    --hostname control-plane \
    --storage "${STORAGE_CONTROL}" \
    --rootfs "${STORAGE_CONTROL}:${CONTROL_ROOTFS}" \
    --memory "${CONTROL_MEM}" \
    --cores "${CONTROL_CORES}" \
    --password "${LXC_ROOT_PASSWORD}" \
    --swap 0 \
    --net0 "${CONTROL_NET0_SPEC}" \
    --net1 "${CONTROL_NET1_SPEC}" \
    --unprivileged 1 \
    --onboot 1 \
    --startup order=1,up=5

  msg_ok "Creating recording LXC (${VMID_RECORDING})"
  pct create "${VMID_RECORDING}" "${TEMPLATE_PATH}" \
    --hostname recording \
    --storage "${STORAGE_RECORDING}" \
    --rootfs "${STORAGE_RECORDING}:${REC_ROOTFS}" \
    --memory "${REC_MEM}" \
    --cores "${REC_CORES}" \
    --password "${LXC_ROOT_PASSWORD}" \
    --swap 0 \
    --net0 "${RECORDING_NET0_SPEC}" \
    --net1 "${RECORDING_NET1_SPEC}" \
    --unprivileged 1 \
    --onboot 1 \
    --startup order=3,up=20

  msg_ok "Recording LXC rootfs attached: ${STORAGE_RECORDING}:${REC_ROOTFS}"

  if [[ "${AUDIO_UDEV}" == "true" && -f "${OUTPUT_DIR}/99-wing.rules" ]]; then
    msg_warn "Udev rule file generated at ${OUTPUT_DIR}/99-wing.rules - copy it into the audio-engine LXC once USB IDs are finalized."
  fi

  msg_ok "Resource creation complete."
}

start_created_resources() {
  section "Starting Created Resources"

  ensure_command pct
  ensure_command qm

  msg_ok "Starting control-plane LXC (${VMID_CONTROL})"
  pct start "${VMID_CONTROL}" >/dev/null 2>&1 || msg_warn "control-plane LXC (${VMID_CONTROL}) may already be running."

  msg_ok "Starting audio-engine LXC (${VMID_AUDIO})"
  pct start "${VMID_AUDIO}" >/dev/null 2>&1 || msg_warn "audio-engine LXC (${VMID_AUDIO}) may already be running."

  msg_ok "Starting recording LXC (${VMID_RECORDING})"
  pct start "${VMID_RECORDING}" >/dev/null 2>&1 || msg_warn "recording LXC (${VMID_RECORDING}) may already be running."

  msg_ok "Startup sequence complete (control-plane -> audio-engine -> recording)."
}

run_apt_maintenance_in_lxc() {
  local vmid="$1"
  local name="$2"

  if ! pct status "${vmid}" 2>/dev/null | grep -q "status: running"; then
    msg_warn "Skipping apt maintenance for ${name} (${vmid}) because it is not running."
    return 0
  fi

  msg_ok "Running apt update/upgrade in ${name} (${vmid})"
  if ! pct exec "${vmid}" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y upgrade'; then
    msg_warn "apt maintenance failed in ${name} (${vmid}). Check networking/DNS inside the container."
  fi
}

run_post_create_apt_maintenance() {
  section "Post-Create Package Maintenance"
  run_apt_maintenance_in_lxc "${VMID_CONTROL}" "control-plane"
  run_apt_maintenance_in_lxc "${VMID_AUDIO}" "audio-engine"
  run_apt_maintenance_in_lxc "${VMID_RECORDING}" "recording"
}

run_repo_sync_in_lxc() {
  local vmid="$1"
  local name="$2"
  local role="$3"

  if ! pct status "${vmid}" 2>/dev/null | grep -q "status: running"; then
    msg_warn "Skipping repository sync for ${name} (${vmid}) because it is not running."
    return 0
  fi

  msg_ok "Syncing repository defaults in ${name} (${vmid}) from ${BOOTSTRAP_REPO_URL}@${BOOTSTRAP_REPO_REF}"
  if ! pct exec "${vmid}" -- env BDRS_REPO_URL="${BOOTSTRAP_REPO_URL}" BDRS_REPO_REF="${BOOTSTRAP_REPO_REF}" BDRS_ROLE="${role}" bash -lc '
    set -euo pipefail

    export DEBIAN_FRONTEND=noninteractive
    if ! command -v git >/dev/null 2>&1; then
      apt-get update
      apt-get install -y git ca-certificates
    fi
    if ! command -v rsync >/dev/null 2>&1; then
      apt-get update
      apt-get install -y rsync
    fi

    mkdir -p /opt/bdrs/repo /opt/bdrs/deploy/current /opt/bdrs/state/user-overrides
    STATE_DIR="/opt/bdrs/state"
    OVERRIDES_DIR="${STATE_DIR}/user-overrides"
    MANIFEST_PATH="${STATE_DIR}/settings-manifest.tsv"

    get_manifest_path() {
      local key="$1"
      if [[ ! -f "${MANIFEST_PATH}" ]]; then
        return 1
      fi
      grep -E "^${key}\|" "${MANIFEST_PATH}" | tail -n 1 | cut -d "|" -f 2-
    }

    set_manifest_path() {
      local key="$1"
      local rel_path="$2"
      local tmp_path
      tmp_path="${MANIFEST_PATH}.tmp"
      if [[ -f "${MANIFEST_PATH}" ]]; then
        grep -E -v "^${key}\|" "${MANIFEST_PATH}" > "${tmp_path}" || true
      else
        : > "${tmp_path}"
      fi
      echo "${key}|${rel_path}" >> "${tmp_path}"
      mv "${tmp_path}" "${MANIFEST_PATH}"
    }

    resolve_setting_rel_path() {
      local key="$1"
      local default_rel="$2"
      shift 2

      local saved_rel
      saved_rel="$(get_manifest_path "${key}" || true)"
      if [[ -n "${saved_rel}" && -f "/opt/bdrs/deploy/current/${saved_rel}" ]]; then
        echo "${saved_rel}"
        return 0
      fi

      local candidate
      for candidate in "$@"; do
        if [[ -f "/opt/bdrs/deploy/current/${candidate}" ]]; then
          echo "${candidate}"
          return 0
        fi
      done

      echo "${default_rel}"
    }

    preserve_override() {
      local rel_path="$1"
      if [[ -f "/opt/bdrs/current/${rel_path}" ]]; then
        mkdir -p "${OVERRIDES_DIR}/$(dirname "${rel_path}")"
        cp -f "/opt/bdrs/current/${rel_path}" "${OVERRIDES_DIR}/${rel_path}"
      fi
    }

    apply_override() {
      local rel_path="$1"
      if [[ -f "${OVERRIDES_DIR}/${rel_path}" ]]; then
        mkdir -p "/opt/bdrs/current/$(dirname "${rel_path}")"
        cp -f "${OVERRIDES_DIR}/${rel_path}" "/opt/bdrs/current/${rel_path}"
      fi
    }

    CONTROL_ENV_REL="$(resolve_setting_rel_path "control_plane_env" "control-plane/.env" "control-plane/.env" "control-plane/config/.env")"
    CONTROL_AUDIO_SETTINGS_REL="$(resolve_setting_rel_path "control_plane_audio_settings" "control-plane/audio-input.settings.json" "control-plane/audio-input.settings.json" "control-plane/config/audio-input.settings.json")"
    AUDIO_ENV_REL="$(resolve_setting_rel_path "audio_engine_env" "audio-engine/.env" "audio-engine/.env" "audio-engine/config/.env")"

    preserve_override "${CONTROL_ENV_REL}"
    preserve_override "${CONTROL_AUDIO_SETTINGS_REL}"
    preserve_override "${AUDIO_ENV_REL}"

    if [[ ! -d /opt/bdrs/repo/.git ]]; then
      if ! git clone --depth 1 --branch "${BDRS_REPO_REF}" "${BDRS_REPO_URL}" /opt/bdrs/repo; then
        git clone "${BDRS_REPO_URL}" /opt/bdrs/repo
        cd /opt/bdrs/repo
        git checkout "${BDRS_REPO_REF}"
      fi
    else
      cd /opt/bdrs/repo
      git fetch --tags origin
      git checkout "${BDRS_REPO_REF}"
      if git ls-remote --exit-code --heads origin "${BDRS_REPO_REF}" >/dev/null 2>&1; then
        git pull --ff-only origin "${BDRS_REPO_REF}"
      fi
    fi

    case "${BDRS_ROLE}" in
      control-plane)
        if [[ -f /opt/bdrs/repo/control-plane/.env.example && ! -f /opt/bdrs/repo/control-plane/.env ]]; then
          cp /opt/bdrs/repo/control-plane/.env.example /opt/bdrs/repo/control-plane/.env
        fi
        if [[ -f /opt/bdrs/repo/control-plane/audio-input.settings.default.json && ! -f /opt/bdrs/repo/control-plane/audio-input.settings.json ]]; then
          cp /opt/bdrs/repo/control-plane/audio-input.settings.default.json /opt/bdrs/repo/control-plane/audio-input.settings.json
        fi
        ;;
      audio-engine)
        if [[ -f /opt/bdrs/repo/audio-engine/.env.example && ! -f /opt/bdrs/repo/audio-engine/.env ]]; then
          cp /opt/bdrs/repo/audio-engine/.env.example /opt/bdrs/repo/audio-engine/.env
        fi
        ;;
      recording)
        ;;
      *)
        echo "unknown role: ${BDRS_ROLE}" >&2
        exit 1
        ;;
    esac

    rsync -a --delete --exclude ".git" /opt/bdrs/repo/ /opt/bdrs/deploy/current/

    ln -sfn /opt/bdrs/deploy/current /opt/bdrs/current

    CONTROL_ENV_REL="$(resolve_setting_rel_path "control_plane_env" "control-plane/.env" "control-plane/.env" "control-plane/config/.env")"
    CONTROL_AUDIO_SETTINGS_REL="$(resolve_setting_rel_path "control_plane_audio_settings" "control-plane/audio-input.settings.json" "control-plane/audio-input.settings.json" "control-plane/config/audio-input.settings.json")"
    AUDIO_ENV_REL="$(resolve_setting_rel_path "audio_engine_env" "audio-engine/.env" "audio-engine/.env" "audio-engine/config/.env")"

    set_manifest_path "control_plane_env" "${CONTROL_ENV_REL}"
    set_manifest_path "control_plane_audio_settings" "${CONTROL_AUDIO_SETTINGS_REL}"
    set_manifest_path "audio_engine_env" "${AUDIO_ENV_REL}"

    case "${BDRS_ROLE}" in
      control-plane)
        if [[ -f "/opt/bdrs/current/${CONTROL_ENV_REL}.example" && ! -f "/opt/bdrs/current/${CONTROL_ENV_REL}" ]]; then
          cp "/opt/bdrs/current/${CONTROL_ENV_REL}.example" "/opt/bdrs/current/${CONTROL_ENV_REL}"
        fi
        if [[ -f "/opt/bdrs/current/$(dirname "${CONTROL_AUDIO_SETTINGS_REL}")/audio-input.settings.default.json" && ! -f "/opt/bdrs/current/${CONTROL_AUDIO_SETTINGS_REL}" ]]; then
          cp "/opt/bdrs/current/$(dirname "${CONTROL_AUDIO_SETTINGS_REL}")/audio-input.settings.default.json" "/opt/bdrs/current/${CONTROL_AUDIO_SETTINGS_REL}"
        fi
        apply_override "${CONTROL_ENV_REL}"
        apply_override "${CONTROL_AUDIO_SETTINGS_REL}"
        ;;
      audio-engine)
        if [[ -f "/opt/bdrs/current/${AUDIO_ENV_REL}.example" && ! -f "/opt/bdrs/current/${AUDIO_ENV_REL}" ]]; then
          cp "/opt/bdrs/current/${AUDIO_ENV_REL}.example" "/opt/bdrs/current/${AUDIO_ENV_REL}"
        fi
        apply_override "${AUDIO_ENV_REL}"
        ;;
      recording)
        ;;
    esac
  '; then
    msg_warn "Repository sync failed in ${name} (${vmid}). Check git access and networking inside the container."
  fi
}

run_post_create_repo_sync() {
  section "Post-Create Repository Sync"
  run_repo_sync_in_lxc "${VMID_CONTROL}" "control-plane" "control-plane"
  run_repo_sync_in_lxc "${VMID_AUDIO}" "audio-engine" "audio-engine"
  run_repo_sync_in_lxc "${VMID_RECORDING}" "recording" "recording"
}

print_sync_only_help() {
  cat <<'EOF'
Usage:
  bdrs.sh --sync-only [options]

Options:
  --repo-url <url>          Git repository URL (default: https://github.com/foxhoundv/BDRS.git)
  --repo-ref <ref>          Branch or tag to sync (default: v0.2.0)
  --audio-vmid <id>         Audio Engine LXC VMID (default: 200)
  --control-vmid <id>       Control Plane LXC VMID (default: 201)
  --recording-vmid <id>     Recording LXC VMID (default: 202)
  -h, --help                Show help
EOF
}

run_sync_only_mode() {
  BOOTSTRAP_REPO_URL="https://github.com/foxhoundv/BDRS.git"
  BOOTSTRAP_REPO_REF="v0.2.0"
  VMID_AUDIO="200"
  VMID_CONTROL="201"
  VMID_RECORDING="202"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo-url)
        BOOTSTRAP_REPO_URL="$2"
        shift 2
        ;;
      --repo-ref)
        BOOTSTRAP_REPO_REF="$2"
        shift 2
        ;;
      --audio-vmid)
        VMID_AUDIO="$2"
        shift 2
        ;;
      --control-vmid)
        VMID_CONTROL="$2"
        shift 2
        ;;
      --recording-vmid)
        VMID_RECORDING="$2"
        shift 2
        ;;
      -h|--help)
        print_sync_only_help
        exit 0
        ;;
      *)
        msg_error "Unknown --sync-only option: $1"
        print_sync_only_help
        exit 1
        ;;
    esac
  done

  section "Repository Sync Only Mode"
  msg_ok "Repo URL: ${BOOTSTRAP_REPO_URL}"
  msg_ok "Repo ref: ${BOOTSTRAP_REPO_REF}"
  msg_ok "VMIDs: control=${VMID_CONTROL}, audio=${VMID_AUDIO}, recording=${VMID_RECORDING}"

  ensure_command pct
  run_post_create_repo_sync
  msg_ok "Sync-only run complete."
  exit 0
}

if [[ "${1:-}" == "--sync-only" ]]; then
  shift
  run_sync_only_mode "$@"
fi

header_info

# This helper is intended to run directly on the Proxmox host.
PVE_HOST="127.0.0.1"
PVE_PORT="8006"
PVE_NODE="$(hostname -s 2>/dev/null || echo pve)"
msg_ok "Detected Proxmox context: ${PVE_HOST}:${PVE_PORT} (node ${PVE_NODE})"

section "Container Template"
ask_choice TEMPLATE_CHOICE "Template choice (ubuntu-24.04 | ubuntu-22.04 | debian-12)" "ubuntu-24.04" "ubuntu-24.04" "ubuntu-22.04" "debian-12"
case "${TEMPLATE_CHOICE}" in
  ubuntu-24.04) TEMPLATE_PATH="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst" ;;
  ubuntu-22.04) TEMPLATE_PATH="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst" ;;
  debian-12) TEMPLATE_PATH="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst" ;;
  *)
    echo "Unsupported template choice: ${TEMPLATE_CHOICE}"
    exit 1
    ;;
esac

section "Storage"
ask_input STORAGE_AUDIO "Storage pool for audio-engine" "local-lvm"
ask_input STORAGE_CONTROL "Storage pool for control-plane" "local-lvm"
ask_input STORAGE_RECORDING "Storage pool for recording" "local-lvm"

section "Network"
ask_choice NETWORK_MODE "Network mode (single-bridge-vlan-tags | separate-bridges)" "single-bridge-vlan-tags" "single-bridge-vlan-tags" "separate-bridges"

if [[ "${NETWORK_MODE}" == "single-bridge-vlan-tags" ]]; then
  ask_input BRIDGE_MAIN "Main bridge name" "vmbr0"
  ask_input VLAN_AUDIO "VLAN ID for audio traffic" "10"
  ask_input VLAN_MGMT "VLAN ID for management" "20"
  BRIDGE_AUDIO="${BRIDGE_MAIN}"
  BRIDGE_MGMT="${BRIDGE_MAIN}"
else
  ask_input BRIDGE_AUDIO "Bridge for audio network" "vmbr10"
  ask_input BRIDGE_MGMT "Bridge for management network" "vmbr20"
  VLAN_AUDIO="0"
  VLAN_MGMT="0"
  BRIDGE_MAIN=""
fi

section "VM and LXC IDs"
ask_input VMID_AUDIO "VMID for audio-engine LXC" "200"
ask_input VMID_CONTROL "VMID for control-plane LXC" "201"
ask_input VMID_RECORDING "VMID for recording LXC" "202"

section "Resource Sizing"
ask_input AUDIO_CORES "audio-engine cores" "4"
ask_input AUDIO_MEM "audio-engine memory MB" "4096"
ask_input AUDIO_ROOTFS "audio-engine rootfs GB" "8"

ask_input CONTROL_CORES "control-plane cores" "2"
ask_input CONTROL_MEM "control-plane memory MB" "2048"
ask_input CONTROL_ROOTFS "control-plane rootfs GB" "8"

ask_input REC_CORES "recording LXC cores" "6"
ask_input REC_MEM "recording LXC memory MB" "8192"
ask_input REC_ROOTFS "recording LXC rootfs GB" "64"

section "Recording and Audio"
msg_ok "Recording will be created as an LXC with preconfigured rootfs and VLAN networking."

ask_input AUDIO_DEVICE_TYPE "Audio source type" "WING"

USB_ID_DEFAULT=""
if [[ "${AUDIO_DEVICE_TYPE,,}" == "wing" || "${AUDIO_DEVICE_TYPE,,}" == *"behringer"* ]]; then
  msg_ok "Scanning USB hardware to help prefill audio vendor:product ID..."
  pick_usb_vendor_product "" "wing"
  USB_ID_DEFAULT="${PICKED_USB_ID}"
fi

ask_input AUDIO_VENDOR_PRODUCT "USB vendor:product (optional now, fill when known)" "${USB_ID_DEFAULT}"
ask_bool AUDIO_UDEV "Generate ALSA udev rule file" "yes"

section "Bootstrap Behavior"
ask_choice FIREWALL_PROFILE "Firewall profile (strict | default | open)" "default" "strict" "default" "open"
ask_input STARTUP_ORDER "Startup order" "control-plane,audio-engine,recording"
ask_input BOOTSTRAP_REPO_URL "Git repo URL for machine defaults" "https://github.com/foxhoundv/BDRS.git"
ask_input BOOTSTRAP_REPO_REF "Git branch/tag for startup defaults" "v0.2.0"
ask_secret_confirm LXC_ROOT_PASSWORD "LXC root password"
ask_bool INSTALL_BUILD_TOOLING "Install Rust/build tooling inside containers" "yes"
ask_bool APPLY_NOW "Create the LXC resources now on this Proxmox host" "yes"
ask_bool START_NOW "Start resources immediately after creation" "yes"
ask_bool RUN_APT_MAINTENANCE "Run apt update && apt -y upgrade in all LXCs after start" "yes"
ask_bool SYNC_DEFAULTS_FROM_REPO "Pull default configs/settings from git repo after startup" "yes"

echo
echo -e "${BL}Configuration Summary${CL}"
echo "- Proxmox (auto-detected): ${PVE_HOST}:${PVE_PORT} (node ${PVE_NODE})"
echo "- Template: ${TEMPLATE_CHOICE} -> ${TEMPLATE_PATH}"
echo "- Network mode: ${NETWORK_MODE}"
echo "- IDs: audio=${VMID_AUDIO}, control=${VMID_CONTROL}, recording=${VMID_RECORDING}"
echo "- Output directory: ${OUTPUT_DIR}"

ask_bool PROCEED "Generate artifacts now" "yes"
if [[ "${PROCEED}" != "true" ]]; then
  msg_warn "Cancelled by user before writing artifacts."
  exit 0
fi

CONFIG_JSON="${OUTPUT_DIR}/bootstrap-config.json"
cat > "${CONFIG_JSON}" <<EOF
{
  "proxmox": {
    "host": "${PVE_HOST}",
    "port": ${PVE_PORT},
    "node": "${PVE_NODE}"
  },
  "template": {
    "choice": "${TEMPLATE_CHOICE}",
    "path": "${TEMPLATE_PATH}"
  },
  "storage": {
    "audioEngine": "${STORAGE_AUDIO}",
    "controlPlane": "${STORAGE_CONTROL}",
    "recording": "${STORAGE_RECORDING}"
  },
  "network": {
    "mode": "${NETWORK_MODE}",
    "bridge": "${BRIDGE_MAIN}",
    "bridgeAudio": "${BRIDGE_AUDIO}",
    "bridgeMgmt": "${BRIDGE_MGMT}",
    "vlanAudio": ${VLAN_AUDIO},
    "vlanMgmt": ${VLAN_MGMT}
  },
  "ids": {
    "audioEngine": ${VMID_AUDIO},
    "controlPlane": ${VMID_CONTROL},
    "recording": ${VMID_RECORDING}
  },
  "resources": {
    "audioEngine": {
      "cores": ${AUDIO_CORES},
      "memoryMb": ${AUDIO_MEM},
      "rootfsGb": ${AUDIO_ROOTFS}
    },
    "controlPlane": {
      "cores": ${CONTROL_CORES},
      "memoryMb": ${CONTROL_MEM},
      "rootfsGb": ${CONTROL_ROOTFS}
    },
    "recording": {
      "cores": ${REC_CORES},
      "memoryMb": ${REC_MEM},
      "rootfsGb": ${REC_ROOTFS}
    }
  },
  "recording": {
    "runtime": "lxc"
  },
  "audio": {
    "deviceType": "${AUDIO_DEVICE_TYPE}",
    "vendorProduct": "${AUDIO_VENDOR_PRODUCT}",
    "generateUdevRule": ${AUDIO_UDEV}
  },
  "bootstrap": {
    "firewallProfile": "${FIREWALL_PROFILE}",
    "startupOrder": "${STARTUP_ORDER}",
    "repoUrl": "${BOOTSTRAP_REPO_URL}",
    "repoRef": "${BOOTSTRAP_REPO_REF}",
    "syncDefaultsFromRepo": ${SYNC_DEFAULTS_FROM_REPO},
    "installBuildTooling": ${INSTALL_BUILD_TOOLING},
    "runAptMaintenance": ${RUN_APT_MAINTENANCE},
    "lxcRootPasswordSet": true
  }
}
EOF

if [[ "${NETWORK_MODE}" == "single-bridge-vlan-tags" ]]; then
  AUDIO_NET_LINE="net0: name=eth0,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET0_LINE="net0: name=eth0,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET1_LINE="net1: name=eth1,bridge=${BRIDGE_MAIN},tag=${VLAN_MGMT},ip=dhcp,firewall=1"
  RECORDING_NET0_LINE="net0: name=eth0,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},ip=dhcp,firewall=1"
  RECORDING_NET1_LINE="net1: name=eth1,bridge=${BRIDGE_MAIN},tag=${VLAN_MGMT},ip=dhcp,firewall=1"
  AUDIO_NET_SPEC="name=eth0,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET0_SPEC="name=eth0,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET1_SPEC="name=eth1,bridge=${BRIDGE_MAIN},tag=${VLAN_MGMT},ip=dhcp,firewall=1"
  RECORDING_NET0_SPEC="name=eth0,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},ip=dhcp,firewall=1"
  RECORDING_NET1_SPEC="name=eth1,bridge=${BRIDGE_MAIN},tag=${VLAN_MGMT},ip=dhcp,firewall=1"
else
  AUDIO_NET_LINE="net0: name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET0_LINE="net0: name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET1_LINE="net1: name=eth1,bridge=${BRIDGE_MGMT},ip=dhcp,firewall=1"
  RECORDING_NET0_LINE="net0: name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  RECORDING_NET1_LINE="net1: name=eth1,bridge=${BRIDGE_MGMT},ip=dhcp,firewall=1"
  AUDIO_NET_SPEC="name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET0_SPEC="name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET1_SPEC="name=eth1,bridge=${BRIDGE_MGMT},ip=dhcp,firewall=1"
  RECORDING_NET0_SPEC="name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  RECORDING_NET1_SPEC="name=eth1,bridge=${BRIDGE_MGMT},ip=dhcp,firewall=1"
fi

cat > "${OUTPUT_DIR}/audio-engine-lxc.conf" <<EOF
# Audio Engine LXC (Generated)
# VMID: ${VMID_AUDIO}
# OS template: ${TEMPLATE_PATH}
arch: amd64
hostname: audio-engine
ostype: ubuntu
cores: ${AUDIO_CORES}
cpulimit: ${AUDIO_CORES}
cpuunits: 2048
memory: ${AUDIO_MEM}
swap: 0
rootfs: ${STORAGE_AUDIO}:${AUDIO_ROOTFS}
${AUDIO_NET_LINE}
features: nesting=1
unprivileged: 0
onboot: 1
startup: order=2,up=10
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir
EOF

cat > "${OUTPUT_DIR}/control-plane-lxc.conf" <<EOF
# Control Plane LXC (Generated)
# VMID: ${VMID_CONTROL}
# OS template: ${TEMPLATE_PATH}
arch: amd64
hostname: control-plane
ostype: ubuntu
cores: ${CONTROL_CORES}
memory: ${CONTROL_MEM}
swap: 0
rootfs: ${STORAGE_CONTROL}:${CONTROL_ROOTFS}
${CONTROL_NET0_LINE}
${CONTROL_NET1_LINE}
unprivileged: 1
onboot: 1
startup: order=1,up=5
EOF

cat > "${OUTPUT_DIR}/recording-lxc.conf" <<EOF
# Recording LXC (Generated)
# VMID: ${VMID_RECORDING}
arch: amd64
hostname: recording
ostype: ubuntu
cores: ${REC_CORES}
memory: ${REC_MEM}
swap: 0
rootfs: ${STORAGE_RECORDING}:${REC_ROOTFS}
${RECORDING_NET0_LINE}
${RECORDING_NET1_LINE}
unprivileged: 1
onboot: 1
startup: order=3,up=20
EOF

if [[ "${AUDIO_UDEV}" == "true" ]]; then
  cat > "${OUTPUT_DIR}/99-wing.rules" <<EOF
# Generated ALSA persistent mapping rule
# Replace values if using a non-WING device
SUBSYSTEM=="sound", ATTRS{idVendor}=="${AUDIO_VENDOR_PRODUCT%%:*}", ATTRS{idProduct}=="${AUDIO_VENDOR_PRODUCT##*:}", SYMLINK+="wing-audio"
EOF
fi

echo
echo "Bootstrap artifacts generated in: ${OUTPUT_DIR}"
echo "- bootstrap-config.json"
echo "- audio-engine-lxc.conf"
echo "- control-plane-lxc.conf"
echo "- recording-lxc.conf"
if [[ "${AUDIO_UDEV}" == "true" ]]; then
  echo "- 99-wing.rules"
fi

if [[ "${APPLY_NOW}" == "true" ]]; then
  apply_generated_resources
  if [[ "${START_NOW}" == "true" ]]; then
    start_created_resources
    if [[ "${RUN_APT_MAINTENANCE}" == "true" ]]; then
      run_post_create_apt_maintenance
    fi
    if [[ "${SYNC_DEFAULTS_FROM_REPO}" == "true" ]]; then
      run_post_create_repo_sync
    fi
  else
    msg_warn "Resources created but not started (START_NOW=no)."
    if [[ "${RUN_APT_MAINTENANCE}" == "true" ]]; then
      msg_warn "Skipped apt maintenance because START_NOW=no. Start LXCs first, then re-run apt manually."
    fi
    if [[ "${SYNC_DEFAULTS_FROM_REPO}" == "true" ]]; then
      msg_warn "Skipped repository sync because START_NOW=no. Start LXCs first, then re-run sync manually."
    fi
  fi
else
  msg_warn "Generation finished. APPLY_NOW=no, so no LXC/VM resources were created."
fi
