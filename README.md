# bijouxlabs - GitOps Homelab

A 12-node k3s cluster running on Proxmox, managed entirely through Flux CD. This is the result of years of iterating through every stage of self-hosting: pasting configs into VMs, a Raspberry Pi running out of RAM, Portainer managing a sprawl of containers across two mini PCs, and eventually reaching the point where the only honest way to understand Kubernetes was to build it and live in it daily.

---

## Background

I spent years in a senior SP networking role: MPLS, BGP, the whole vendor-locked stack. I learn best by doing and while there were plenty of options (Packet tracer, GNS3, Hardware labs) my experience was roughly the same: spend ages rewriting boilerplate configs, reading vendor docs and pasting configs. Once that was done and the routes were learned or pings returned, that was kind of the end of meaningful work on the lab. The gaps you don't close by stopping there are significant. You had an idea of how to implement a feature and some approximation of what production would look like but it felt inert and unresponsive.

When I moved almost exclusively into Linux, scripting and systems work I had to learn a lot of new tools and techniques — many of which would be the same upstream systems that integrated into the network infrastructure.

The self-hosting journey ran parallel to that. A Pi doing DNS ad-blocking and a few containers quickly hit resource limits (and in 2015, finding ARM-compatible images for anything was its own adventure). A cheap mini PC from Amazon to add resources also added many new variables to account for. Home Assistant wired to a handful of IoT sensors was a genuine turning point — the first time the lab felt like it was actually doing something.

Fast forward: containers spread across two mini PCs and entropy quietly crept in: logins, OS versions, config directories and daemons to remember. It worked until it didn't. Portainer helped manage some of that complexity for a while. I learned of Kubernetes and was immediately intimidated. I tried the books and online tutorials but it was difficult to map that understanding to a context I was familiar with. Slowly the decision to use my own lab to learn Kubernetes became clear.

---

## Architecture

```
Proxmox Hypervisor
├── VyOS VM (gateway — dual NIC: WAN→ONT, LAN→switch, flat 192.168.0.0/24)
└── k3s cluster (12 nodes)
    ├── kmaster01 / kmaster02 / kmaster03   (HA control plane + kube-vip VIP)
    └── kworker01 – kworker09               (workload nodes)
```

**Control plane HA** is handled by kube-vip as a DaemonSet, providing a static VIP across the three masters.

**Storage** is split intentionally:
- kmaster01 + kmaster02 have dedicated 502Gi NVMe drives mounted at `/mnt/longhorn-nvme`, tagged `nvme` in Longhorn
- Worker nodes have ~20-25Gi free on their OS disks — usable for small PVCs, too small for anything large
- PVCs that need NVMe use the `longhorn-nvme` StorageClass (`diskSelector: nvme, numberOfReplicas: 2`) to pin replicas to both NVMe nodes; relying on PVC annotations alone is unreliable as Longhorn ignores them in favour of the global default

**Networking** uses MetalLB in L2 mode for LoadBalancer IPs and Traefik as the ingress controller, with TLS terminated via Cloudflare's ACME DNS challenge. A `cloudflared` deployment runs as cluster infrastructure to expose selected services externally via Cloudflare Tunnel without port forwarding.

---

## Stack

| Layer | Tool |
|---|---|
| Hypervisor | Proxmox |
| Network gateway | VyOS |
| Kubernetes | k3s |
| GitOps | Flux CD v2 |
| Ingress | Traefik v3 |
| Load Balancer | MetalLB (L2) |
| Control Plane HA | kube-vip |
| Storage | Longhorn |
| CNI | Cilium + Hubble |
| Database operator | CloudNative-PG |
| Secrets | SOPS + age |
| External tunnel | cloudflared (Cloudflare Tunnel) |

---

## Applications

| App | Description |
|---|---|
| [Immich](https://immich.app) | Self-hosted photo library; CNPG cluster with VectorChord for ML embeddings |
| [Vaultwarden](https://github.com/dani-garcia/vaultwarden) | Self-hosted Bitwarden-compatible password manager |
| [Paperless-ngx](https://docs.paperless-ngx.com) | Document management with OCR; sidecars: Valkey, Apache Tika, Gotenberg |
| [Karakeep](https://karakeep.app) | Bookmark manager with AI-powered crawling, tagging and search via local Ollama |
| [Home Assistant](https://www.home-assistant.io) | IoT and home automation |
| [n8n](https://n8n.io) | Workflow automation with public webhook exposure via Cloudflare Tunnel |
| [Homepage](https://gethomepage.dev) | Unified service dashboard |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) | Service uptime monitoring |
| [Opengist](https://github.com/thomiceli/opengist) | Self-hosted gist service |
| [Copyparty](https://github.com/9001/copyparty) | Self-hosted file sharing |
| [StefHQ](https://github.com/SLBij/stefhq) | Personal AI assistant — FastAPI + SvelteKit + ARQ worker + pgvector + Ollama |
| [Radar](https://github.com/skyhook-io/radar) | Kubernetes cluster visibility — workloads, traffic (via Hubble), events |
| [Qdrant](https://qdrant.tech) | Vector database for semantic search and RAG |
| [Ollama](https://ollama.com) | Local LLM inference server (`llama3.2`, `nomic-embed-text`, `moondream`) |
| [Grafana + Prometheus](https://grafana.com) | Cluster metrics and dashboards (kube-prometheus-stack) |

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
│   ├── cloudflared/    # Cloudflare Tunnel deployment (cluster infrastructure)
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
- **postBuild `$(VAR)` substitution never reliably worked** in this cluster — proven when a live Traefik HelmRelease was found with a literal `$(LB_IP_TRAEFIK)` in it months after it was supposed to be substituted. The strategy is now to hardcode non-sensitive values directly in manifests.

Each fix exposed the next layer. The resolution was to stop fighting the tool: hardcode non-sensitive values directly in manifests, keep SOPS strictly for actual secrets, and annotate anything Flux shouldn't touch after initial apply with `kustomize.toolkit.fluxcd.io/ssa: ignore`.

The cluster has been stable since.

---

## Secrets Management

SOPS with age encryption. The `.sops.yaml` at the repo root defines which paths are encrypted and with which key. The age public key is committed; the private key lives only on machines that need to decrypt.

Flux decrypts secrets at apply time via the `kustomize-controller` SOPS provider. Nothing is ever stored in plaintext in git.

One hard-learned rule: use `sops edit <file>` to modify already-encrypted files. Running `sops -e -i` on an already-encrypted file double-encrypts it and breaks everything silently.

---

## Roadmap

- [x] VyOS VM on Proxmox replacing OpenWrt router (dual NIC, flat 192.168.0.0/24)
- [x] Cloudflare Tunnel (`cloudflared`) deployed as cluster infrastructure
- [ ] Tailscale subnet router for mobile access over tailnet (in progress)
- [ ] IoT VLAN (VLAN 20) for smart devices — on hold; switch is accessible but VLAN rollout requires enabling VLAN trunking across the Proxmox cluster (moving all nodes to a tagged VLAN), which is high-risk to do live. Previous attempts hit OpenWrt SSID-VLAN limitations and VyOS VIF/IP conflicts on the same interface.
- [ ] WiFi 6 APs with 802.11r/k/v roaming to replace mixed ZTE/Huawei setup
- [ ] CrowdSec agent on VyOS for IoT egress monitoring
- [ ] More DRAM NVME's for longhorn
