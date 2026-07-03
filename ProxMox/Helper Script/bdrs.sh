#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/generated"
mkdir -p "${OUTPUT_DIR}"

prompt() {
  local key="$1"
  local question="$2"
  local default="$3"
  local value
  read -r -p "${question} [${default}]: " value
  if [[ -z "${value}" ]]; then
    value="${default}"
  fi
  printf -v "${key}" '%s' "${value}"
}

prompt_bool() {
  local key="$1"
  local question="$2"
  local default="$3"
  local value
  read -r -p "${question} [${default}] (yes/no): " value
  value="${value,,}"
  if [[ -z "${value}" ]]; then
    value="${default}"
  fi
  case "${value}" in
    y|yes|true|1) value="true" ;;
    n|no|false|0) value="false" ;;
    *)
      echo "Invalid input for ${key}. Use yes or no."
      exit 1
      ;;
  esac
  printf -v "${key}" '%s' "${value}"
}

echo "Broadcast RTA Proxmox Bootstrap"
echo "This script collects first-run answers and generates Proxmox config templates."

prompt PVE_HOST "Proxmox host or IP" "192.168.1.57"
prompt PVE_PORT "Proxmox API/UI port" "8006"
prompt PVE_NODE "Proxmox node name" "pve"

prompt TEMPLATE_CHOICE "Template choice (ubuntu-24.04 | ubuntu-22.04 | debian-12)" "ubuntu-24.04"
case "${TEMPLATE_CHOICE}" in
  ubuntu-24.04) TEMPLATE_PATH="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst" ;;
  ubuntu-22.04) TEMPLATE_PATH="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst" ;;
  debian-12) TEMPLATE_PATH="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst" ;;
  *)
    echo "Unsupported template choice: ${TEMPLATE_CHOICE}"
    exit 1
    ;;
esac

prompt STORAGE_AUDIO "Storage pool for audio-engine" "local-lvm"
prompt STORAGE_CONTROL "Storage pool for control-plane" "local-lvm"
prompt STORAGE_RECORDING "Storage pool for recording" "local-lvm"

prompt NETWORK_MODE "Network mode (single-bridge-vlan-tags | separate-bridges)" "single-bridge-vlan-tags"

if [[ "${NETWORK_MODE}" == "single-bridge-vlan-tags" ]]; then
  prompt BRIDGE_MAIN "Main bridge name" "vmbr0"
  prompt VLAN_AUDIO "VLAN ID for audio traffic" "10"
  prompt VLAN_MGMT "VLAN ID for management" "20"
  prompt VLAN_INTERNET "VLAN ID for internet/update traffic" "30"
  BRIDGE_AUDIO="${BRIDGE_MAIN}"
  BRIDGE_MGMT="${BRIDGE_MAIN}"
  BRIDGE_INTERNET="${BRIDGE_MAIN}"
else
  prompt BRIDGE_AUDIO "Bridge for audio network" "vmbr10"
  prompt BRIDGE_MGMT "Bridge for management network" "vmbr20"
  prompt BRIDGE_INTERNET "Bridge for internet/update network" "vmbr30"
  VLAN_AUDIO="0"
  VLAN_MGMT="0"
  VLAN_INTERNET="0"
  BRIDGE_MAIN=""
fi

prompt VMID_AUDIO "VMID for audio-engine LXC" "200"
prompt VMID_CONTROL "VMID for control-plane LXC" "201"
prompt VMID_RECORDING "VMID for recording VM" "202"

prompt AUDIO_CORES "audio-engine cores" "4"
prompt AUDIO_MEM "audio-engine memory MB" "4096"
prompt AUDIO_ROOTFS "audio-engine rootfs GB" "8"

prompt CONTROL_CORES "control-plane cores" "2"
prompt CONTROL_MEM "control-plane memory MB" "2048"
prompt CONTROL_ROOTFS "control-plane rootfs GB" "8"

prompt REC_CORES "recording VM cores" "6"
prompt REC_MEM "recording VM memory MB" "8192"

prompt RECORDING_DISK_MODE "recording disk mode (virtual-disk | nvme-passthrough)" "virtual-disk"
prompt RECORDING_PASSTHROUGH "recording passthrough ref (hostpci0/scsi ref, optional)" ""

prompt AUDIO_DEVICE_TYPE "Audio source type" "WING"
prompt AUDIO_VENDOR_PRODUCT "USB vendor:product (optional now, fill when known)" ""
prompt_bool AUDIO_UDEV "Generate ALSA udev rule file" "yes"

prompt FIREWALL_PROFILE "Firewall profile (strict | default | open)" "default"
prompt STARTUP_ORDER "Startup order" "control-plane,audio-engine,recording"
prompt_bool INSTALL_BUILD_TOOLING "Install Rust/build tooling inside containers" "yes"

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
else
  AUDIO_NET_LINE="net0: name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET0_LINE="net0: name=eth0,bridge=${BRIDGE_AUDIO},ip=dhcp,firewall=1"
  CONTROL_NET1_LINE="net1: name=eth1,bridge=${BRIDGE_MGMT},ip=dhcp,firewall=1"
  RECORDING_NET0_LINE="net0: virtio,bridge=${BRIDGE_AUDIO},firewall=1"
  RECORDING_NET1_LINE="net1: virtio,bridge=${BRIDGE_MGMT},firewall=1"
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
