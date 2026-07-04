terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint  = var.pve_endpoint  # any cluster node API, e.g. https://192.168.0.211:8006/
  api_token = var.pve_api_token # "user@realm!tokenid=uuid"
  insecure  = true              # homelab PVE uses self-signed certs

  # bpg uploads the cloud-init snippet to each node's `local` storage over SSH,
  # so it needs SSH to the target nodes as well as the API token.
  ssh {
    agent    = true
    username = "root"
  }
}
