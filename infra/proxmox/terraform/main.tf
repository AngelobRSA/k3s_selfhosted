# Per-master cloud-init user-data, uploaded as a snippet to the target node's
# `local` storage. Terraform renders the k3s server-join with the real token.
resource "proxmox_virtual_environment_file" "user_data" {
  for_each = var.masters

  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.value.node

  source_raw {
    data = templatefile("${path.module}/../cloud-init/k3s-server.yaml.tmpl", {
      hostname            = each.key
      k3s_token           = var.k3s_token
      ssh_authorized_keys = var.ssh_authorized_keys
    })
    file_name = "${each.key}-user-data.yaml"
  }
}

# Per-worker cloud-init user-data. Same shape as the master snippet but renders
# the agent-join template (no control-plane taint, no Longhorn storage deps).
resource "proxmox_virtual_environment_file" "user_data_worker" {
  for_each = var.workers

  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.value.node

  source_raw {
    data = templatefile("${path.module}/../cloud-init/k3s-agent.yaml.tmpl", {
      hostname            = each.key
      k3s_token           = var.k3s_token
      k3s_url             = var.k3s_url
      ssh_authorized_keys = var.ssh_authorized_keys
    })
    file_name = "${each.key}-user-data.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "master" {
  for_each = var.masters

  name      = each.key
  node_name = each.value.node
  vm_id     = each.value.vmid
  tags      = ["k3s", "control-plane", "terraform"]

  clone {
    vm_id = each.value.template_vmid # node-local template from build-template.sh
    full  = true
  }

  agent {
    enabled = true # cloud-init installs + starts qemu-guest-agent
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 20 # grow the ~10GB cloud image to 20GB for a control-plane node
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.gateway
      }
    }

    dns {
      servers = [var.dns_server]
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data[each.key].id
  }

  # Let cloud-init own the hostname; ignore agent-reported churn after join.
  lifecycle {
    ignore_changes = [initialization[0].user_data_file_id]
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  for_each = var.workers

  name      = each.key
  node_name = each.value.node
  vm_id     = each.value.vmid
  tags      = ["k3s", "worker", "terraform"]

  clone {
    vm_id = each.value.template_vmid # node-local template from build-template.sh
    full  = true
  }

  agent {
    enabled = true # cloud-init installs + starts qemu-guest-agent
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 20
  }

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.gateway
      }
    }

    dns {
      servers = [var.dns_server]
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data_worker[each.key].id
  }

  lifecycle {
    ignore_changes = [initialization[0].user_data_file_id]
  }
}

output "masters" {
  value = { for k, m in var.masters : k => {
    node = m.node
    vmid = m.vmid
    ip   = m.ip
  } }
}

output "workers" {
  value = { for k, w in var.workers : k => {
    node = w.node
    vmid = w.vmid
    ip   = w.ip
  } }
}
