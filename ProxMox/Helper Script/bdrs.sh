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

  if ! list_usb_candidates; then
    printf '%s' "${chosen}"
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
        printf '%s' "${chosen}"
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
        printf '%s' "${chosen}"
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
    --swap 0 \
    --net0 "${CONTROL_NET0_SPEC}" \
    --net1 "${CONTROL_NET1_SPEC}" \
    --unprivileged 1 \
    --onboot 1 \
    --startup order=1,up=5

  msg_ok "Creating recording VM (${VMID_RECORDING})"
  qm create "${VMID_RECORDING}" \
    --name recording \
    --memory "${REC_MEM}" \
    --cores "${REC_CORES}" \
    --scsihw virtio-scsi-pci \
    --net0 "${RECORDING_NET0_SPEC}" \
    --net1 "${RECORDING_NET1_SPEC}" \
    --onboot 1 \
    --startup order=3,up=20

  if [[ "${RECORDING_DISK_MODE}" == "virtual-disk" ]]; then
    qm set "${VMID_RECORDING}" --scsi0 "${STORAGE_RECORDING}:64"
    msg_ok "Attached default recording disk: ${STORAGE_RECORDING}:64"
  elif [[ -n "${RECORDING_PASSTHROUGH}" ]]; then
    local passthrough_key="${RECORDING_PASSTHROUGH%%:*}"
    local passthrough_val="${RECORDING_PASSTHROUGH#*:}"
    qm set "${VMID_RECORDING}" "--${passthrough_key}" "${passthrough_val}"
    msg_ok "Applied passthrough option: --${passthrough_key} ${passthrough_val}"
  else
    msg_warn "Recording VM created without storage passthrough option."
  fi

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

  msg_ok "Starting recording VM (${VMID_RECORDING})"
  qm start "${VMID_RECORDING}" >/dev/null 2>&1 || msg_warn "recording VM (${VMID_RECORDING}) may already be running."

  msg_ok "Startup sequence complete (control-plane -> audio-engine -> recording)."
}

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
  ask_input VLAN_INTERNET "VLAN ID for internet/update traffic" "30"
  BRIDGE_AUDIO="${BRIDGE_MAIN}"
  BRIDGE_MGMT="${BRIDGE_MAIN}"
  BRIDGE_INTERNET="${BRIDGE_MAIN}"
else
  ask_input BRIDGE_AUDIO "Bridge for audio network" "vmbr10"
  ask_input BRIDGE_MGMT "Bridge for management network" "vmbr20"
  ask_input BRIDGE_INTERNET "Bridge for internet/update network" "vmbr30"
  VLAN_AUDIO="0"
  VLAN_MGMT="0"
  VLAN_INTERNET="0"
  BRIDGE_MAIN=""
fi

section "VM and LXC IDs"
ask_input VMID_AUDIO "VMID for audio-engine LXC" "200"
ask_input VMID_CONTROL "VMID for control-plane LXC" "201"
ask_input VMID_RECORDING "VMID for recording VM" "202"

section "Resource Sizing"
ask_input AUDIO_CORES "audio-engine cores" "4"
ask_input AUDIO_MEM "audio-engine memory MB" "4096"
ask_input AUDIO_ROOTFS "audio-engine rootfs GB" "8"

ask_input CONTROL_CORES "control-plane cores" "2"
ask_input CONTROL_MEM "control-plane memory MB" "2048"
ask_input CONTROL_ROOTFS "control-plane rootfs GB" "8"

ask_input REC_CORES "recording VM cores" "6"
ask_input REC_MEM "recording VM memory MB" "8192"

section "Recording and Audio"
ask_choice RECORDING_DISK_MODE "recording disk mode (virtual-disk | nvme-passthrough)" "virtual-disk" "virtual-disk" "nvme-passthrough"
ask_input RECORDING_PASSTHROUGH "recording passthrough ref (hostpci0/scsi ref, optional)" ""

ask_input AUDIO_DEVICE_TYPE "Audio source type" "WING"

USB_ID_DEFAULT=""
if [[ "${AUDIO_DEVICE_TYPE,,}" == "wing" || "${AUDIO_DEVICE_TYPE,,}" == *"behringer"* ]]; then
  msg_ok "Scanning USB hardware to help prefill audio vendor:product ID..."
  USB_ID_DEFAULT="$(pick_usb_vendor_product "" "wing")"
fi

ask_input AUDIO_VENDOR_PRODUCT "USB vendor:product (optional now, fill when known)" "${USB_ID_DEFAULT}"
ask_bool AUDIO_UDEV "Generate ALSA udev rule file" "yes"

section "Bootstrap Behavior"
ask_choice FIREWALL_PROFILE "Firewall profile (strict | default | open)" "default" "strict" "default" "open"
ask_input STARTUP_ORDER "Startup order" "control-plane,audio-engine,recording"
ask_bool INSTALL_BUILD_TOOLING "Install Rust/build tooling inside containers" "yes"
ask_bool APPLY_NOW "Create the LXC/VM resources now on this Proxmox host" "yes"
ask_bool START_NOW "Start resources immediately after creation" "yes"

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
    "bridgeInternet": "${BRIDGE_INTERNET}",
    "vlanAudio": ${VLAN_AUDIO},
    "vlanMgmt": ${VLAN_MGMT},
    "vlanInternet": ${VLAN_INTERNET}
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
      "memoryMb": ${REC_MEM}
    }
  },
  "recording": {
    "diskMode": "${RECORDING_DISK_MODE}",
    "passthroughRef": "${RECORDING_PASSTHROUGH}"
  },
  "audio": {
    "deviceType": "${AUDIO_DEVICE_TYPE}",
    "vendorProduct": "${AUDIO_VENDOR_PRODUCT}",
    "generateUdevRule": ${AUDIO_UDEV}
  },
  "bootstrap": {
    "firewallProfile": "${FIREWALL_PROFILE}",
    "startupOrder": "${STARTUP_ORDER}",
    "installBuildTooling": ${INSTALL_BUILD_TOOLING}
  }
}
EOF

if [[ "${NETWORK_MODE}" == "single-bridge-vlan-tags" ]]; then
  AUDIO_NET_LINE="net0: name=eth0,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET0_LINE="net0: name=eth0,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET1_LINE="net1: name=eth1,bridge=${BRIDGE_MAIN},tag=${VLAN_MGMT},ip=dhcp,firewall=1"
  RECORDING_NET0_LINE="net0: virtio,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},firewall=1"
  RECORDING_NET1_LINE="net1: virtio,bridge=${BRIDGE_MAIN},tag=${VLAN_MGMT},firewall=1"
  AUDIO_NET_SPEC="name=eth0,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET0_SPEC="name=eth0,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET1_SPEC="name=eth1,bridge=${BRIDGE_MAIN},tag=${VLAN_MGMT},ip=dhcp,firewall=1"
  RECORDING_NET0_SPEC="virtio,bridge=${BRIDGE_MAIN},tag=${VLAN_AUDIO},firewall=1"
  RECORDING_NET1_SPEC="virtio,bridge=${BRIDGE_MAIN},tag=${VLAN_MGMT},firewall=1"
else
  AUDIO_NET_LINE="net0: name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET0_LINE="net0: name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET1_LINE="net1: name=eth1,bridge=${BRIDGE_MGMT},ip=dhcp,firewall=1"
  RECORDING_NET0_LINE="net0: virtio,bridge=${BRIDGE_AUDIO},firewall=1"
  RECORDING_NET1_LINE="net1: virtio,bridge=${BRIDGE_MGMT},firewall=1"
  AUDIO_NET_SPEC="name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET0_SPEC="name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET1_SPEC="name=eth1,bridge=${BRIDGE_MGMT},ip=dhcp,firewall=1"
  RECORDING_NET0_SPEC="virtio,bridge=${BRIDGE_AUDIO},firewall=1"
  RECORDING_NET1_SPEC="virtio,bridge=${BRIDGE_MGMT},firewall=1"
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

cat > "${OUTPUT_DIR}/recording-vm.conf" <<EOF
# Recording VM (Generated)
# VMID: ${VMID_RECORDING}
cores: ${REC_CORES}
memory: ${REC_MEM}
scsihw: virtio-scsi-pci
${RECORDING_NET0_LINE}
${RECORDING_NET1_LINE}
onboot: 1
startup: order=3,up=20
EOF

if [[ "${RECORDING_DISK_MODE}" == "nvme-passthrough" && -n "${RECORDING_PASSTHROUGH}" ]]; then
  echo "${RECORDING_PASSTHROUGH}" >> "${OUTPUT_DIR}/recording-vm.conf"
fi

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
echo "- recording-vm.conf"
if [[ "${AUDIO_UDEV}" == "true" ]]; then
  echo "- 99-wing.rules"
fi

if [[ "${APPLY_NOW}" == "true" ]]; then
  apply_generated_resources
  if [[ "${START_NOW}" == "true" ]]; then
    start_created_resources
  else
    msg_warn "Resources created but not started (START_NOW=no)."
  fi
else
  msg_warn "Generation finished. APPLY_NOW=no, so no LXC/VM resources were created."
fi
