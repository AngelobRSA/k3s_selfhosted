# bijouxlabs - GitOps Homelab

A 12-node k3s cluster running on Proxmox, managed entirely through Flux CD. This is the result of years of iterating through every stage of self-hosting: pasting configs into VMs, a Raspberry Pi running out of RAM, Portainer managing a sprawl of containers across two mini PCs, and eventually reaching the point where the only honest way to understand Kubernetes was to build it and live in it daily.

---

## Background

I spent years in a senior SP networking role: MPLS, BGP, the whole vendor-locked stack. The labs were real but they always felt incomplete: spin up some VMs, paste a config, send a few test packets, call it done. The gaps you don't close by stopping there are significant.

When I moved almost exclusively into Linux, the contrast was stark. Coming from an environment where adding functionality meant opening a TAC case, suddenly a single command could extend or replace entire subsystems. That shift changed how I thought about infrastructure.

The self-hosting journey ran parallel to that. A Pi doing DNS ad-blocking and a few containers quickly hit resource limits (and in 2015, finding ARM-compatible images for anything was its own adventure). A mini PC fixed the resources. Home Assistant wired to a handful of IoT sensors was a genuine turning point, the first time the lab felt like it was actually doing something.

Fast forward: containers spread across two mini PCs managed by Portainer. It worked until it didn't. Entropy crept in quietly: which VM should this container live on, how much RAM does it get, and at some point you're just keeping a mental map of every socket in the stack.

The only way to actually understand Kubernetes was to stop reading about it.

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
| CNI | Cilium |
| Database operator | CloudNative-PG |
| Secrets | SOPS + age |
| Intrusion detection | CrowdSec + ForwardAuth bouncer |

---

## Applications

| App | Description |
|---|---|
| [Immich](https://immich.app) | Self-hosted photo library, CNPG cluster with VectorChord for ML embeddings |
| [n8n](https://n8n.io) | Workflow automation |
| [Home Assistant](https://www.home-assistant.io) | IoT and home automation (in progress) |
| [Homepage](https://gethomepage.dev) | Unified service dashboard |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) | Service monitoring |
| [Opengist](https://github.com/nicholaswilde/opengist) | Self-hosted gist service |
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
│   ├── cilium/         # CNI
│   └── bijouxlabs/     # Cluster-wide middleware + Proxmox node resources
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

- Home Assistant (manifests exist, not yet wired into `apps/kustomization.yaml`)
- CrowdSec agent on OpenWrt router for IoT egress monitoring
- Cloudflare Tunnel for n8n public webhook exposure
- Upgrade Immich OCIRepository from deprecated `v1beta2` to `v1`
