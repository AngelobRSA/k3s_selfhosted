# Proxmox → k3s node automation (Tier B)

Unattended k3s **control-plane** node provisioning for the `bijouxlab` PVE cluster:
a scripted Rocky 10 cloud-init template + Terraform clone + cloud-init k3s join.
No manual OS install, no hand-built golden image.

Current use: grow the control plane **3 → 5 masters** (kmaster04 on `node04g4800`,
kmaster05 on `proxmox`). See `../../` memory `project-k3s-master-expansion`.

```
build-template.sh              # run per node — makes the Rocky10 cloud-init template
cloud-init/k3s-server.yaml.tmpl # k3s server-join user-data (rendered by Terraform)
terraform/                      # clones template → places + configures each master
```

## Why a script *and* Terraform

The cluster has **no shared storage** — a template on one node's `local-lvm` can't be
cloned onto another node. So `build-template.sh` runs once **per target node** to place an
identical, reproducible template there; Terraform then clones it locally on each node.
(This is also why the old node01 `Rocky10-cloudinit-base` (VMID 101) couldn't be reused —
node-local, and its `cicustom` snippet was missing.)

## One-time prerequisites

1. **PVE API token** for Terraform (on any node):
   ```
   pveum user add terraform@pve
   pveum aclmod / -user terraform@pve -role Administrator
   pveum user token add terraform@pve tf --privsep 0
   ```
   Put the resulting `terraform@pve!tf=<uuid>` in `terraform.tfvars` (gitignored) or
   `export TF_VAR_pve_api_token=...`.

2. **k3s join token** — the *server* token, from an existing master:
   ```
   ssh angelo@192.168.0.154 sudo cat /var/lib/rancher/k3s/server/token
   ```
   Store it encrypted (matches the repo's SOPS/age discipline), never in plaintext:
   ```
   echo "TF_VAR_k3s_token=<token>" > terraform/secrets.enc.env
   sops -e -i terraform/secrets.enc.env   # ensure infra/** is covered by .sops.yaml
   ```

## Deploy

```bash
# 1. Build the template on each target node (from your workstation):
for spec in node04g4800:9004 proxmox:9010; do
  n=${spec%%:*}; v=${spec##*:}
  ip=$( [ "$n" = proxmox ] && echo 192.168.0.110 || echo 192.168.0.214 )
  scp ~/.ssh/id_ed25519.pub root@$ip:/root/tmpl_key.pub
  scp infra/proxmox/build-template.sh root@$ip:/root/
  ssh root@$ip "TEMPLATE_VMID=$v bash /root/build-template.sh"
done

# 2. Clone + join both masters:
cd infra/proxmox/terraform
terraform init
sops exec-env secrets.enc.env 'terraform apply'
```

## Verify the join

```bash
kubectl get nodes -o wide          # kmaster04/05 Ready, control-plane,etcd,master
kubectl get nodes -l node-role.kubernetes.io/control-plane   # 5 total
sudo k3s etcd-snapshot ls          # or: kubectl -n kube-system get pods | grep etcd
```

Expect a **5-member etcd** quorum (tolerates 2 host failures).

## Follow-ups / gotchas

- **NIC name:** confirm the guest enumerates the API NIC as `ens18` — kube-vip is pinned
  to it (`cluster/kube-vip/daemonset.yaml`). The template mirrors existing kmaster hardware
  so it should, but check `ip a` on first boot.
- **Master taint:** applied at join (`--node-taint ...control-plane=true:NoSchedule`) to
  match the existing tainted masters. Don't rely on post-hoc patching.
- **kube-vip election timeout:** open resilience TODO — the 2026-06-21 outage was a VIP
  failover lag cascade. Good moment to tune it while expanding the control plane.
- **proxmox host is memory-tight** (12GB, VyOS uses 4GB): kmaster05 is capped at 3GB and
  shares `local-lvm` with the gateway VM — watch etcd fsync latency there.
