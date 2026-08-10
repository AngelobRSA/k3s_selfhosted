variable "pve_endpoint" {
  description = "Proxmox API endpoint (any bijouxlab node)"
  type        = string
  default     = "https://192.168.0.211:8006/"
}

variable "pve_api_token" {
  description = "Proxmox API token: 'user@realm!tokenid=uuid'"
  type        = string
  sensitive   = true
}

variable "k3s_token" {
  description = <<-EOT
    Cluster server-join token — contents of /var/lib/rancher/k3s/server/token
    on an existing master (NOT the agent node-token). Provide via SOPS, e.g.:
      sops exec-env secrets.enc.env 'terraform apply'
    with TF_VAR_k3s_token set inside. Never commit it in plaintext.
  EOT
  type        = string
  sensitive   = true
}

# New masters: one per master-less physical host. Templates are node-local
# (no shared storage) so template_vmid differs per node — build with
# build-template.sh before applying.
variable "masters" {
  description = "New control-plane nodes to create"
  type = map(object({
    node          = string
    vmid          = number
    template_vmid = number
    ip            = string # CIDR, e.g. 192.168.0.12/24
    memory        = number # MiB
    cores         = number
  }))
  # Measured 2026-08-10 (kubectl top / free -m on hosts). Masters run hot on
  # memory; the two TF-managed ones sit on the two most constrained hosts.
  #
  #   NODE        ALLOC     USED    MEM%   HOST         HOST RAM  COMMITTED
  #   kmaster03   ~3.6G    2996Mi    82%   node03m920     31.1G       —
  #   kmaster04    4096M   2603Mi    71%   node04g4800    31.1G     36.0G (!)
  #   kmaster05    4096M   2502Mi    68%   node05m920      7.6G      4.0G
  #   kmaster02    6144M   2454Mi    51%   node02m910     31.1G     28.0G
  #
  # node04g4800 is ALREADY overcommitted (~5G): kworker04/05/07/09 hold 8192M
  # each but use only ~2.0-2.6G. Raising kmaster04 realistically means shrinking
  # those workers first — they are hand-built, NOT in var.workers, so that is a
  # `qm set` on the host, not a TF change.
  #
  # ⚠️ DRIFT — do not silently "fix" in this block:
  #   - kmaster05 `node` reads "proxmox" but the VM actually runs on node05m920
  #     (moved 2026-08-09). Changing node_name on an existing VM can force
  #     RECREATION — needs a state mv / import, not an edit.
  #   - kmaster05 `memory` reads 3072 but the live VM is 4096.
  #   - The "12GB total, VyOS uses 4GB" comment describes the OLD host and is
  #     stale; node05m920 has 7.6G total with ~2.1G available.
  default = {
    kmaster04 = {
      node          = "node04g4800"
      vmid          = 405
      template_vmid = 9004
      ip            = "192.168.0.12/24"

      # DEFERRED 2026-08-10 — choose memory/cores for the two TF-managed masters.
      # Constraints to weigh:
      #   - kmaster04 host node04g4800: 31.1G RAM / 6 cores, already ~36G
      #     committed. Any increase here is only safe if you also shrink the
      #     four 8192M workers on that host (they use ~2.0-2.6G each).
      #   - kmaster05 host node05m920: 7.6G RAM / 6 cores, ~2.1G available.
      #     Leave the hypervisor ~1.5-2G; that caps kmaster05 near 5120M.
      #   - An etcd voter's steady state here is ~2.5G; the 3.2G "peak" seen on
      #     kmaster02 was k3s looping on a corrupt DB, not normal load.
      #   - cores: hosts are 6-core; every master currently gets 2. etcd is more
      #     fsync/latency-bound than CPU-bound, so more cores rarely helps it.
      memory = 4096
      cores  = 2
    }
    kmaster05 = {
      node          = "proxmox" # ⚠️ drift: really on node05m920 (see note above)
      vmid          = 501
      template_vmid = 9010
      ip            = "192.168.0.32/24"
      memory        = 3072 # ⚠️ drift: live VM is 4096
      cores         = 2
    }
  }
}

# New workers: k3s agents (no control-plane, no Longhorn storage deps). Empty by
# default — the existing hand-built workers are NOT managed here. Add an entry
# only to have Terraform create a brand-new worker (build its template first).
variable "workers" {
  description = "New agent/worker nodes to create"
  type = map(object({
    node          = string
    vmid          = number
    template_vmid = number
    ip            = string # CIDR, e.g. 192.168.0.40/24
    memory        = number # MiB
    cores         = number
  }))
  default = {}
}

variable "ssh_authorized_keys" {
  description = "Public keys granted to the angelo user on new masters/workers"
  type        = list(string)
  default = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkBVQalthJY9Nlsd8TMwSxZbyLAkdj5laxPLz4I4BRG angelo@laptop",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOZFcI0Nha8eU9/5GQj9Ph8aHTIN7cpc060ZxhrMNqvN angelo@desktop",
  ]
}

variable "gateway" {
  type    = string
  default = "192.168.0.1"
}

variable "dns_server" {
  type    = string
  default = "192.168.0.1"
}

variable "k3s_url" {
  type    = string
  default = "https://192.168.0.220:6443"
}
