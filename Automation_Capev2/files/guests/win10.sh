#!/usr/bin/env bash
# Creates a Windows 10 x64 KVM guest for use as a CAPE analysis target.
#
# VM name    : cape-win10
# RAM        : 6 GB, 2 vCPUs, 60 GB disk
#
# Required ISO files in /var/lib/libvirt/images/iso/:
#   win10.iso       - Windows 10 x64 installation image
#   virtio-win.iso  - VirtIO drivers
#                     https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/
#
# Safe re-run: if VM already exists the script prints its state and exits 0
# without touching it.
#
# After guest install: set up CAPE agent, snapshot.

set -euo pipefail

ISO_DIR="/var/lib/libvirt/images/iso"
VM_NAME="cape-win10"
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

if [[ ! -f "$ISO_DIR/win10.iso" ]]; then
  echo "Error: $ISO_DIR/win10.iso not found." >&2; exit 1
fi
if [[ ! -f "$ISO_DIR/virtio-win.iso" ]]; then
  echo "Error: $ISO_DIR/virtio-win.iso not found." >&2
  echo "  Download: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/" >&2
  exit 1
fi

# ---- libvirt connectivity ----
# Use monolithic libvirtd (disable split virtqemud stack if present).
# kvm-qemu.sh may set up split daemons, but monolithic libvirtd is more
# reliable in nested-KVM / VMware environments.

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
  --vcpus 2 \
  --cpu host-model \
  --disk path="$DISK_PATH",size=60,format=qcow2,bus=virtio \
  --os-variant win10 \
  --network network=default,model=virtio \
  --graphics spice \
  --video qxl \
  --cdrom "$ISO_DIR/win10.iso" \
  --disk path="$ISO_DIR/virtio-win.iso",device=cdrom \
  --machine q35 \
  --noautoconsole

echo ""
echo "[*] VM $VM_NAME created. Connect via virt-manager or:"
echo "    sudo $VIRSH -c $LIBVIRT_URI start $VM_NAME   # ak bola zastavená"
echo "    virt-viewer -c $LIBVIRT_URI $VM_NAME"
