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
  default = {
    kmaster04 = {
      node          = "node04g4800"
      vmid          = 405
      template_vmid = 9004
      ip            = "192.168.0.12/24"
      memory        = 4096
      cores         = 2
    }
    kmaster05 = {
      node          = "proxmox"
      vmid          = 501
      template_vmid = 9010
      ip            = "192.168.0.32/24"
      memory        = 3072 # tight host (12GB total, VyOS uses 4GB)
      cores         = 2
    }
  }
}

variable "ssh_authorized_key" {
  description = "Public key granted to the angelo user on new masters"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkBVQalthJY9Nlsd8TMwSxZbyLAkdj5laxPLz4I4BRG angelo.bijoux@rsaweb.net"
}

variable "gateway" {
  type    = string
  default = "192.168.0.1"
}

variable "dns_server" {
  type    = string
  default = "192.168.0.1"
}
