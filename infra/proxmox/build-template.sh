#!/usr/bin/env bash
# Build a Rocky Linux 10 cloud-init template on the LOCAL Proxmox node.
#
# Run this AS ROOT on each target PVE node (node04g4800 and proxmox), because
# the bijouxlab cluster has no shared storage — templates are node-local and
# cannot be cloned across nodes. See infra/proxmox/README.md.
#
# Idempotent: if the template VMID already exists it is destroyed and rebuilt.
#
# Usage (on the PVE node):
#   scp ~/.ssh/id_ed25519.pub root@<node>:/root/tmpl_key.pub
#   TEMPLATE_VMID=9004 ./build-template.sh        # on node04g4800
#   TEMPLATE_VMID=9010 ./build-template.sh        # on proxmox
set -euo pipefail

TEMPLATE_VMID="${TEMPLATE_VMID:?set TEMPLATE_VMID (e.g. 9004 on node04g4800, 9010 on proxmox)}"
TEMPLATE_NAME="${TEMPLATE_NAME:-Rocky10-cloudinit-base}"
STORAGE="${STORAGE:-local-lvm}"          # lvmthin datastore for the VM disk
BRIDGE="${BRIDGE:-vmbr0}"
CIUSER="${CIUSER:-angelo}"
SSHKEY_FILE="${SSHKEY_FILE:-/root/tmpl_key.pub}"
IMG_URL="https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2"
IMG_PATH="/var/lib/vz/template/iso/$(basename "$IMG_URL")"

[[ -f "$SSHKEY_FILE" ]] || { echo "!! missing $SSHKEY_FILE — scp your pubkey there first"; exit 1; }

echo ">> [$(hostname)] building template $TEMPLATE_VMID ($TEMPLATE_NAME) on $STORAGE"

# Fetch the cloud image once (cached).
if [[ ! -f "$IMG_PATH" ]]; then
  echo ">> downloading Rocky 10 GenericCloud image"
  mkdir -p "$(dirname "$IMG_PATH")"
  curl -fL --retry 3 -o "$IMG_PATH" "$IMG_URL"
fi

# Rebuild cleanly if it already exists.
if qm status "$TEMPLATE_VMID" &>/dev/null; then
  echo ">> destroying existing VMID $TEMPLATE_VMID"
  qm destroy "$TEMPLATE_VMID" --purge
fi

# Create the VM. Hardware mirrors the existing kmaster VMs so the guest NIC
# enumerates as ens18 (kube-vip is pinned to ens18) and the serial console works
# for the cloud image.
qm create "$TEMPLATE_VMID" \
  --name "$TEMPLATE_NAME" \
  --machine q35 \
  --cpu host \
  --cores 2 \
  --memory 2048 \
  --net0 "virtio,bridge=$BRIDGE" \
  --scsihw virtio-scsi-single \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1 \
  --ostype l26

# Import the disk directly to the target storage (PVE 8 one-shot import).
qm set "$TEMPLATE_VMID" --scsi0 "$STORAGE:0,import-from=$IMG_PATH"
qm set "$TEMPLATE_VMID" --boot "order=scsi0"

# Cloud-init drive + baseline identity. Per-VM user-data (the k3s join) is
# injected by Terraform at clone time via user_data_file_id — NOT baked here.
qm set "$TEMPLATE_VMID" --ide2 "$STORAGE:cloudinit"
qm set "$TEMPLATE_VMID" --ciuser "$CIUSER"
qm set "$TEMPLATE_VMID" --sshkeys "$SSHKEY_FILE"

qm template "$TEMPLATE_VMID"
echo ">> done: template $TEMPLATE_VMID ready on $(hostname)"
