#!/usr/bin/env bash
# Creates a Windows 11 x64 KVM guest for use as a CAPE analysis target.
#
# VM name    : cape-win11
# RAM        : 6 GB, 4 vCPUs, 80 GB disk, UEFI + TPM 2.0
#
# Required ISO file in /var/lib/libvirt/images/iso/:
#   win11.iso
#
# Safe re-run: if VM already exists the script prints its state and exits 0
# without touching it.
#
# After guest install: set up CAPE agent, snapshot.

set -euo pipefail

ISO_DIR="/var/lib/libvirt/images/iso"
ISO_FILE="win11.iso"
VM_NAME="cape-win11"
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
LIBVIRT_URI="qemu:///system"
VIRSH="${VIRSH:-$(command -v virsh 2>/dev/null || echo /usr/bin/virsh)}"
VIRT_INSTALL="${VIRT_INSTALL:-$(command -v virt-install 2>/dev/null || true)}"

# ---- pre-flight: tools ----

if [[ -z "$VIRT_INSTALL" || ! -x "$VIRT_INSTALL" ]]; then
  echo "ERROR: virt-install not found in PATH." >&2
  echo "  Run: sudo bash /opt/CAPEv2/installer/kvm-qemu.sh virtmanager cape" >&2
  exit 1
fi
echo "[*] Using virt-install: $VIRT_INSTALL"

if [[ ! -f "$ISO_DIR/$ISO_FILE" ]]; then
  echo "Error: $ISO_DIR/$ISO_FILE not found." >&2; exit 1
fi

if ! command -v swtpm >/dev/null 2>&1; then
  echo "Error: swtpm is not installed (required for TPM 2.0)." >&2
  echo "  sudo apt install swtpm swtpm-tools" >&2
  exit 1
fi

# ---- libvirt connectivity ----
# Use monolithic libvirtd (disable split virtqemud stack if present).

sudo systemctl unmask \
  libvirtd.service libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket \
  virtlogd.service virtlogd.socket virtlockd.service virtlockd.socket \
  2>/dev/null || true
sudo systemctl disable --now \
  virtqemud.service virtqemud.socket virtqemud-ro.socket virtqemud-admin.socket \
  2>/dev/null || true
sudo systemctl enable --now \
  virtlogd.socket virtlockd.socket \
  libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket libvirtd.service \
  >/dev/null 2>&1 || true
sudo systemctl restart libvirtd.service >/dev/null 2>&1 || true

if ! sudo "$VIRSH" -c "$LIBVIRT_URI" list --all >/dev/null 2>&1; then
  echo "ERROR: cannot connect to libvirt at $LIBVIRT_URI." >&2
  echo "  sudo journalctl -u libvirtd.service -u libvirtd.socket -n 80 --no-pager" >&2
  exit 1
fi

# ---- default network ----
# Use net-list for the active-state check. It is locale-independent.
# net-info grep is unreliable across libvirt versions and locales.

if ! sudo "$VIRSH" -c "$LIBVIRT_URI" net-info default >/dev/null 2>&1; then
  if [[ -f /usr/share/libvirt/networks/default.xml ]]; then
    sudo "$VIRSH" -c "$LIBVIRT_URI" net-define /usr/share/libvirt/networks/default.xml
  else
    echo "ERROR: default libvirt network is missing and /usr/share/libvirt/networks/default.xml was not found." >&2
    exit 1
  fi
fi

# Always attempt net-start; "already active" is not an error.
if ! sudo "$VIRSH" -c "$LIBVIRT_URI" net-list --all | grep -qE "^\s*default\s+active"; then
  echo "[*] Starting default libvirt network..."
  sudo "$VIRSH" -c "$LIBVIRT_URI" net-start default 2>/dev/null || true
fi

sudo "$VIRSH" -c "$LIBVIRT_URI" net-autostart default 2>/dev/null || true

# Verify final state.
if ! sudo "$VIRSH" -c "$LIBVIRT_URI" net-list --all | grep -qE "^\s*default\s+active"; then
  echo "ERROR: libvirt default network is still not active after start attempt." >&2
  echo "  sudo ip link set virbr0 down 2>/dev/null || true" >&2
  echo "  sudo ip link delete virbr0 type bridge 2>/dev/null || true" >&2
  echo "  sudo systemctl restart libvirtd && sudo virsh -c qemu:///system net-start default" >&2
  exit 1
fi

# ---- safe re-run: if VM already defined, just report state ----

if sudo "$VIRSH" -c "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
  state="$(sudo "$VIRSH" -c "$LIBVIRT_URI" domstate "$VM_NAME" 2>/dev/null || true)"
  echo "VM '$VM_NAME' already exists. State: ${state:-unknown}"
  if [[ "$state" == "running" ]]; then
    echo "  Connect: virt-viewer -c $LIBVIRT_URI $VM_NAME"
  else
    echo "  Start:   sudo $VIRSH -c $LIBVIRT_URI start $VM_NAME"
    echo "  Connect: virt-viewer -c $LIBVIRT_URI $VM_NAME"
  fi
  echo "  Delete:  sudo $VIRSH -c $LIBVIRT_URI destroy $VM_NAME 2>/dev/null; sudo $VIRSH -c $LIBVIRT_URI undefine $VM_NAME --remove-all-storage"
  exit 0
fi

if [[ -e "$DISK_PATH" ]]; then
  echo "Error: disk $DISK_PATH exists but VM '$VM_NAME' is not defined." >&2
  echo "  Remove it manually if disposable: sudo rm -f '$DISK_PATH'" >&2
  exit 1
fi

# ---- detect QEMU binary ----
# Verify QEMU is present; libvirt auto-detects it from the standard path.
# (--emulator flag dropped: newer virt-install does not support it.)

QEMU_BIN=""
for candidate in \
    /usr/local/bin/qemu-system-x86_64 \
    /usr/libexec/qemu-kvm \
    /usr/bin/qemu-system-x86_64 \
    /usr/bin/kvm; do
  if [[ -x "$candidate" ]]; then
    QEMU_BIN="$candidate"
    break
  fi
done

if [[ -z "$QEMU_BIN" ]]; then
  echo "ERROR: no QEMU binary found. kvm-qemu.sh may not have completed." >&2
  exit 1
fi
echo "[*] Using QEMU binary: $QEMU_BIN (auto-detected by libvirt)"

# ---- create VM ----

echo "[*] Creating VM $VM_NAME..."
sudo "$VIRT_INSTALL" \
  --connect "$LIBVIRT_URI" \
  --virt-type kvm \
  --name "$VM_NAME" \
  --ram 6144 \
  --vcpus 4 \
  --cpu host-model \
  --disk path="$DISK_PATH",size=80,format=qcow2,bus=virtio \
  --os-variant win11 \
  --network network=default,model=virtio \
  --graphics spice \
  --video qxl \
  --cdrom "$ISO_DIR/$ISO_FILE" \
  --boot uefi \
  --features smm=on \
  --machine q35 \
  --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
  --noautoconsole

echo ""
echo "[*] VM $VM_NAME created. Connect via virt-manager or:"
echo "    sudo $VIRSH -c $LIBVIRT_URI start $VM_NAME   # ak bola zastavená"
echo "    virt-viewer -c $LIBVIRT_URI $VM_NAME"