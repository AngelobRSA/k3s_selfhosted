# bijouxlabs - GitOps Homelab

A 12-node k3s cluster running on Proxmox, managed entirely through Flux CD. This is the result of years of iterating through every stage of self-hosting: pasting configs into VMs, a Raspberry Pi running out of RAM, Portainer managing a sprawl of containers across two mini PCs, and eventually reaching the point where the only honest way to understand Kubernetes was to build it and live in it daily.

---

## Background

I spent years in a senior SP networking role: MPLS, BGP, the whole vendor-locked stack. I learn best by doing and while there were plenty of options (Packet tracer, GNS3, Hardware labs) My experience was roughly the same: spend ages rewriting boilerplate configs, reading vendor docs and pasting configs.Once that was done and the routes were learned or pings returned, that was kind of the end of meaningful work on the lab.The gaps you don't close by stopping there are significant. You had an idea of how to implement a feature and some approximation of what production would look like but it felt inert and unresponsive. 

When I moved almost exclusively into Linux, Scripting & Systems work I had to learn a lot of new tools and techniques. Many of which would be the the same upsteam systems that integrated into the network infrastructure.

The self-hosting journey ran parallel to that. A Pi doing DNS ad-blocking and a few containers quickly hit resource limits (and in 2015, finding ARM-compatible images for anything was its own adventure). A cheap mini PC from amazon to add resources also added many new variables to account for. Home Assistant wired to a handful of IoT sensors was a genuine turning point, the first time the lab felt like it was actually doing something.

Fast forward: containers spread across two mini PCs & Entropy quietly crept in: logins, OS versions, config directories & daemons to remember. It worked until it didn't. Portainer helped manage some of that complexity for a while. I learned of kubernetes and was immediately intimidated. I tried the books and online tutorials but it was difficult to map that understanding to a context that I was familiar with. Slowly the decision to use my own lab to learn kubernetes became clear.


---

## Architecture

```
Proxmox Hypervisor
└── k3s cluster (12 nodes)
    ├── kmaster01 / kmaster02 / kmaster03   (HA control plane + kube-vip VIP)
    └── kworker01 – kworker09               (workload nodes)
```

**Control plane HA** is handled by kube-vip as a DaemonSet, providing a static VIP across the three masters.

**Storage** is split intentionally:
- kmaster01 + kmaster02 have dedicated 502Gi NVMe drives mounted at `/mnt/longhorn-nvme` (the only nodes that can host large PVCs)
- Worker nodes have ~20-25Gi free on their OS disks, insufficient for anything meaningful
- Large PVCs (>15Gi) are pinned to the NVMe nodes via `volume.longhorn.io/number-of-replicas: "2"`

**Networking** uses MetalLB in L2 mode for LoadBalancer IPs, Traefik as the ingress controller with TLS terminated via Cloudflare's ACME DNS challenge. CrowdSec sits in front of Traefik as a ForwardAuth bouncer, checking every request against the LAPI before it reaches a service.

---

## Stack

| Layer | Tool |
|---|---|
| Hypervisor | Proxmox |
| Kubernetes | k3s |
| GitOps | Flux CD v2 |
| Ingress | Traefik v3 |
| Load Balancer | MetalLB (L2) |
| Control Plane HA | kube-vip |
| Storage | Longhorn |
| CNI | Cilium + Hubble |
| Database operator | CloudNative-PG |
| Secrets | SOPS + age |
| Intrusion detection | CrowdSec + ForwardAuth bouncer |

---

## Applications

| App | Description |
|---|---|
| [Immich](https://immich.app) | Self-hosted photo library, CNPG cluster with VectorChord for ML embeddings |
| [Vaultwarden](https://github.com/dani-garcia/vaultwarden) | Self-hosted Bitwarden-compatible password manager |
| [Paperless-ngx](https://docs.paperless-ngx.com) | Document management with OCR; sidecars: Valkey (Redis), Apache Tika, Gotenberg |
| [Home Assistant](https://www.home-assistant.io) | IoT and home automation |
| [n8n](https://n8n.io) | Workflow automation |
| [Homepage](https://gethomepage.dev) | Unified service dashboard |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) | Service uptime monitoring |
| [Opengist](https://github.com/thomiceli/opengist) | Self-hosted gist service |
| [Copyparty](https://github.com/9001/copyparty) | Self-hosted file sharing |
| [Radar](https://github.com/skyhook-io/radar) | Kubernetes cluster visibility — workloads, traffic (via Hubble), events |
| [Qdrant](https://qdrant.tech) | Vector database for semantic search and RAG |
| [Grafana + Prometheus](https://grafana.com) | Cluster metrics and dashboards (kube-prometheus-stack) |
| iperf3 | Network performance testing endpoint |

---

## Repo Structure

```
.
├── cluster/
│   ├── flux-system/    # Flux bootstrapping + Kustomization CRs
│   ├── traefik/        # Ingress controller + TLS config
│   ├── metallb/        # L2 LoadBalancer IP pools
│   ├── longhorn/       # Distributed storage + StorageClass
│   ├── kube-vip/       # Control plane VIP DaemonSet
│   ├── cnpg/           # CloudNative-PG operator
│   ├── cilium/         # CNI + Hubble relay/UI
│   └── bijouxlabs/     # Proxmox node reverse-proxy (headless Services + Endpoints + Ingresses per host)
└── apps/
    └── <app>/          # Per-app Kustomization, HelmRelease, SOPS secrets
```

Secrets are encrypted with SOPS/age and committed directly to the repo. LAN IPs and credentials stay encrypted; domain names and non-sensitive config are hardcoded in manifests.

---

## The Hard Part

Getting Flux and SOPS to cooperate without everything blowing up took longer than I'd like to admit, and involved several compounding failures that were genuinely difficult to untangle.

The root issue: **kustomize replacement blocks execute before SOPS decryption**. Some early manifests used kustomize replacements to inject values from a SOPS-encrypted ConfigMap. What actually got substituted was raw `ENC[AES256_GCM,...]` ciphertext. MetalLB's admission webhook rejected the invalid CIDR format in `IPAddressPool.spec.addresses` and blocked all Flux reconciliation cluster-wide.

That alone would've been manageable. But the failure was compounding:

- `flux-system` wasn't included in the cluster Kustomization resources list. With `prune: true` enabled, Flux was quietly deleting its own CRDs and controller Deployments on every successful reconcile, then immediately re-applying them. It looked like things were working fine.
- A single typo (`NAMESPACES_APPLICATIONS` instead of `NAMESPACE_APPLICATIONS`) caused Flux to abort all `$(VAR)` postBuild substitution silently across the entire cluster, leaving raw variable tokens in every manifest.
- kube-vip had a chicken-and-egg dependency: it needed the `bijouxlabs-replacements` ConfigMap to exist before it could reconcile, but the ConfigMap was only available after the cluster was up.

Each fix exposed the next layer. The resolution was to stop fighting the tool: hardcode non-sensitive values directly in manifests, keep SOPS strictly for actual secrets, and annotate anything Flux shouldn't touch after initial apply with `kustomize.toolkit.fluxcd.io/ssa: ignore`.

The cluster has been stable since.

---

## Secrets Management

SOPS with age encryption. The `.sops.yaml` at the repo root defines which paths are encrypted and with which key. The age public key is committed; the private key lives only on machines that need to decrypt.

Flux decrypts secrets at apply time via the `kustomize-controller` SOPS provider. Nothing is ever stored in plaintext in git.

---

## Roadmap

- VyOS VM on Proxmox to replace OpenWrt router (dual NIC: WAN→ONT, LAN→switch)
- IoT VLAN (VLAN 20) for smart devices, HPE managed switch already in place
- WiFi 6 APs with 802.11r/k/v roaming to replace mixed ZTE/Huawei setup
- Tailscale subnet router for mobile access over tailnet
- Cloudflare Tunnel (`cloudflared` pod) for n8n public webhook exposure
- CrowdSec agent on VyOS for IoT egress monitoring
