# Captain's Log — bijouxlabs

> *"Space is disease and danger wrapped in darkness and silence."*
> So is a homelab, but with worse cable management.

This is the narrative history of the cluster: what broke, what we thought was
happening, what was actually happening, and what we changed because of it.

**Why this file exists.** The YAML in this repo is declarative — it states the
desired end state of the cluster and nothing else. It should not carry the story
of how we arrived at each value. That story lives here. If you find yourself
writing a paragraph of incident history into a config comment, write it here
instead and leave a one-line pointer behind.

Entries are **reverse-chronological** — most recent first, because the most
recent is usually the one you need. Standing Orders at the bottom collect the
durable lessons, stripped of narrative.

---

## Ship's roster

Six Proxmox hosts, fourteen k3s nodes, one etcd master per host.

| Host | IP | k8s nodes | Notes |
|---|---|---|---|
| `proxmox` | .110 | — | vyosGateway only — 🔴 LAN gateway + DNS |
| `node01m910` | .211 | kmaster01, kworker01 | i5-8500T 35W, NVMe |
| `node02m910` | .212 | kmaster02, kworker02 | i5-8500T 35W, NVMe |
| `node03m920` | .213 | kmaster03, kworker03/06/08 | i5-8500T 35W, NVMe |
| `node04g4800` | .214 | kmaster04, kworker04/05/07/09 | **i5-8500 65W**, diskless — biggest blast radius |
| `node05m920` | .72 | kmaster05 | i5-8500T 35W, PCIe SM961 |

**Two independent quorums.** etcd (5 members, quorum 3) and corosync (6 nodes,
quorum 4). Both tolerate two hosts down. **Never take three hosts down at once.**
Adding node05 as a sixth corosync member bought zero extra tolerance — an
even-numbered cluster never does.

**The core gotcha:** nothing in the stack is natively hypervisor-aware. Longhorn
and Traefik both key on `kubernetes.io/hostname`, which three VMs on one physical
host satisfy perfectly while offering no real redundancy. The
`topology.kubernetes.io/zone=<proxmox-host>` labels exist to fix this and are
GitOps-managed in `cluster/topology/nodes.yaml`.

---

## Stardate 2026-08-17 — "The Ghost Ship" 🔴 OPEN

**node04g4800 stopped answering at 04:52:55 and never came back — while running perfectly.**

At 04:52:55 node04's node-exporter, sshd, pveproxy and ICMP all went silent
simultaneously. `ProxmoxHostDown` fired, critical, and read as *"Every VM on this
host is down. Check physical power/NIC."*

Every word of that was wrong.

All five VMs stayed `Ready` with unbroken uptime dating to the Aug 13 repaste.
Corosync stayed quorate at 6/6. `pve-ha-lrm` kept writing its heartbeat into the
cluster filesystem **every single second, in lockstep with node03** — 10:17:25
against node03's 10:17:24, twenty-nine hours after the host "went down."

The discriminating test: a `hostNetwork` pod scheduled onto a VM **on node04's own
bridge** could not ping the host — one hop, no cable, no switch — while reaching
node03 across the physical network in 0.4 ms. The fault was inside node04's own
IP stack. Not the NIC, not the cable, not the switch, not the power.

**What it was not.** conntrack sat at 0.00% of limit. Memory held flat at 43.5%
available with no leak. Load was ~1.0 across six cores. CPU temperature was
67–73°C, entirely normal for this host. Every metric was clean right up to the
instant it wedged, and stayed clean afterwards.

The shape of the failure is specific: **long-established UDP flows (corosync)
survive; every new inbound connection (SSH, 8006, 9100, ICMP echo) is dropped.**
That is a netfilter/neighbour-layer signature, not a dead machine.

**Standing order added:** a host that stops answering while its VMs keep running
is *wedged*, not dead, and must not be power-cycled blind — a reboot destroys the
only evidence. Get console, capture `dmesg`, then reboot. `HostManagementPlaneWedged`
exists to name this state so `ProxmoxHostDown` stops mis-directing triage.

---

## Stardate 2026-08-13 — "The Repaste That Wasn't" ⚠️ CORRECTED

node04 was moved to the bottom of the cabinet, cleaned, given a 120 mm external
fan, and had its CPU thermal paste replaced. The host was powered down cleanly —
all five VMs shut down properly, etcd 4/5, corosync 5/6, zero incidents.

The immediate readings looked like a triumph: **67.6°C → 59.4°C, a −8.2°C win.**

**That number was an artifact and has been retracted.** It compared a 6-hour
"before" window against a **20-minute** "after" window taken immediately
post-boot, when the VMs had not yet spun up and the chassis was still cold.

Measured properly over comparable windows:

| Window | Avg | Max |
|---|---|---|
| 24 h before repaste | 69.3°C | 78.0°C |
| 72 h after repaste | 68.9°C | 77.0°C |

**The repaste bought 0.4°C.** Within noise. The paste was not the problem.

**Why node04 runs hot, and why that is not a fault.** It is the only host in the
fleet with a full 65 W CPU — an i5-8500 — in an `800 G4 DM` Desktop Mini chassis.
Every sibling runs a 35 W T-series part. Over the same 72 h window:

| Host | Avg | Max |
|---|---|---|
| **node04g4800 (65 W)** | **68.9°C** | **77.0°C** |
| node02m910 | 58.7°C | 64.0°C |
| node03m920 | 57.0°C | 65.0°C |
| node05m920 | 55.2°C | 63.0°C |
| node01m910 | 52.9°C | 60.0°C |
| proxmox | 45.8°C | 64.0°C |

Roughly double the thermal load in the same thermal budget yields ~11–14°C. That
is expected physics, not a defect. Tjmax is 100°C; 77°C is not close to trouble.

**Standing order added:** do not chase node04's temperature with cooling tweaks.
It is a cooling-*capacity* characteristic, not a workload problem — the machine
idles at ~69°C under ~17% CPU, so there is no workload to move that would help.
The real defect is the alert: `HostCPUTemperatureWarning` at 70°C is calibrated
for the 35 W hosts and fires on node04's normal operating temperature. An alert
that cries wolf on one machine's healthy idle trains you to ignore all of them.

---

## Stardate 2026-08-10 — "142 Gigabytes of Nothing"

Investigation into why kmaster02 held zero Longhorn replicas found 49 orphaned
replica directories consuming **~142 GB** — 105 GB of it on kmaster02 itself, a
node with no live replicas at all. One volume had **ten** stale copies.

Root cause: `orphanAutoDeletion` (a bool) was **renamed in Longhorn 1.9** to
`orphanResourceAutoDeletion` (a semicolon-separated list). Helm silently dropped
the now-unknown key, the live setting sat at `""`, and nothing was ever reaped.

```yaml
orphanAutoDeletion: true                                  # silently ignored on 1.9+
orphanResourceAutoDeletion: "replica-data;instance"       # correct
```

**The sting in the tail:** orphan data *skews the replica scheduler*. Longhorn
scores candidate disks by available space, so 105 GB of phantom usage made
kmaster02 look nearly full and every rebuild landed elsewhere. The "empty node"
and the "wasted space" were the same bug wearing two hats.

⚠️ `replica-auto-balance` would **not** have fixed this. It balances one volume's
own replicas across zones; it cannot address a cross-volume capacity skew.
Longhorn has no global capacity rebalancer — moving existing replicas is manual.

---

## Stardate 2026-08-09 — "The Silent Hang"

node05 was unreachable for ~6 hours. **It was never down.** The OS ran the entire
time — journald, smartd and pveproxy all logging happily. Its NIC's transmit unit
had wedged:

```
kernel: e1000e 0000:00:1f.6 eno1: Detected Hardware Unit Hang:
```

It tracks the NIC revision, not the machine model:

| Host | NIC | Hangs logged |
|---|---|---|
| node05m920 | I219-LM **`8086:15bb`** rev 10 | **10,335** |
| node03m920 | I219-LM **`8086:15bb`** rev 10 | **3,384** |
| node04g4800 | I219-LM **`8086:15bb`** rev 10 | 97 |
| node01m910 / node02m910 | I219-LM `8086:15b7` | 0 |
| proxmox | Realtek r8169 | 0 |

node03 and node04 had been accumulating these silently for months — a strong
candidate for past unexplained NotReady events.

**Why it fools you.** Powered on, fans spinning, link lights normal. A blank
screen is just console blanking. Ctrl+Alt+Del appearing to "fix" it is
misleading — that is systemd performing a *clean reboot*, visible in the journal,
not a firmware reset, and it does **not** mean the box was hung at POST.

Mitigation: `ethtool -K eno1 tso off gso off`, made persistent.

**Same day, two more findings.** The USB-vs-PCIe enclosure mystery was solved:
`0 blocks` meant **USB 2.0 fallback**, not a dead enclosure. Severed SuperSpeed
pairs in the cable drop the link to 480 Mb/s and 2.5 W, and an NVMe needs 3–8 W.
Check `cat /sys/bus/usb/devices/*/speed` first — `480` means a broken link. And
node05m920 joined as the sixth host, its internal PCIe SM961 becoming a fourth
Longhorn zone.

---

## Stardate 2026-08-07/08 — "Operation Blackout"

A full-cluster shutdown for cabinet reorganisation: new shelves, recabled,
new cooling, dust cleared from every node, node05 racked. Angelo started after a
full working day, finished at 03:30, and slept most of Saturday. Bring-up
completed that afternoon: 5/5 masters, 168 pods running, vaultwarden restored.

**The big lesson: post-maintenance faults are physical until proven otherwise.**

Two masters failed on bring-up, both because their VM config held a hard
reference to a USB enclosure that had been physically disturbed that night.
kmaster04's QEMU simply refused to start. kmaster03 booted into a dead
`/mnt/longhorn-nvme` and dropped to **emergency mode** — and since console is
useless on locked-root cloud images, it needed an offline fstab edit via
`losetup -fP` (`kpartx` is not installed on these hosts; `losetup -P` does the
same job).

⚠️ **Attribution correction.** This was initially recorded as "a third enclosure
hardware failure across two brands." That over-claimed. The failure logged at
03:13 — *inside* the window when everything was unplugged, moved and replugged —
after a clean month of service. These nodes power on automatically when mains
returns, so node03 booted before its external was reconnected and never
remounted. **Reseat before condemning.**

Also learned: `replicas: 0` workloads are invisible to every obvious check. And
node02 is *not* the flaky host — node04 is.

---

## Stardate 2026-08-08 — "Half a Fix Is Worse Than None"

Adding `nofail` to kmaster03's Longhorn fstab line correctly stopped a dead
USB-NVMe from dropping the master into emergency mode. It booted in 28 s with the
disk absent. **Within two hours it caused data loss instead.**

**Longhorn registers a disk by *path*, not by device.** With the NVMe unmounted,
`/mnt/longhorn-nvme` still existed as an ordinary directory on the node's 31 GB
**OS disk**. longhorn-manager found a writable directory, wrote a fresh
`longhorn-disk.cfg` with a new UUID, and started creating replicas there — on the
same disk as etcd. Both `immich-db` volumes came up on those empty replicas, the
CSI driver saw no filesystem, ran `mkfs`, and the live database became a blank
ext4.

Longhorn *did* eventually flag it — but only **after** writing.

The complete fix needs both halves:

```
UUID=... /mnt/longhorn-nvme ext4 noatime,nodiratime,nofail,x-systemd.device-timeout=10 0 0
chattr +i /mnt/longhorn-nvme      # while UNMOUNTED
```

`nofail` lets the node boot; `chattr +i` makes the bare mountpoint unwritable so
Longhorn fails loudly instead of adopting the OS disk. A mounted filesystem masks
the immutable flag, so it costs nothing when the disk is healthy. Applied
fleet-wide 2026-08-09, all five masters verified guarded.

---

## Stardate 2026-08-05 — "The Volume That Lied"

kmaster04's `longhorn-nvme512` hit an ext4 I/O error and took five replicas with
it. Three volumes had enough copies elsewhere and rebuilt automatically. Two did
not — and `immich-library` went to `robustness=faulted`.

**The real bug:** `immich-library` was spec'd `numberOfReplicas: 2` but **only one
replica object ever existed**. The PVC used the annotation
`volume.longhorn.io/number-of-replicas: "2"`, which Longhorn silently ignores.

Restored from B2 backup with **zero data loss**, verified by confirming the newest
asset in the database predated the snapshot.

🔴 **Still open:** nothing alerts on a degraded Longhorn volume. "Volume degraded"
is not in the default kube-prometheus-stack rules, so a volume can sit at one
replica indefinitely and you will not know.

**Diagnostic lesson worth its own line.** The presenting symptom was
`CreateContainerError` / `context deadline exceeded` / `failed to reserve
container name` — which looks *exactly* like a wedged containerd. It was an I/O
hang on a dead Longhorn volume; kubelet's create call was blocked on the
unresponsive mount. **Check volume health before blaming the container runtime.**

---

## Stardate 2026-08-04 — "Counting the Dead"

Discovered while investigating an apparent 30°C temperature drop that turned out
to be Prometheus dying together with its host.

**The method is the finding.** `journalctl --list-boots`, then check each boot's
*last line*. A boot ending in `Journal stopped` is clean; one ending mid-sentence
is an abrupt power loss. This turns "did it crash?" into a countable history.

Five of node04's last seven boots ended abruptly. Cross-referencing every other
host's boot list separated out one site-wide mains event (prepaid electricity
running out, UPS then draining) from **four solo abrupt resets**: Jul 15, Jul 26,
Jul 27, Aug 4. Uptimes before each: 11.4 d → 2.5 d → 0.7 d → 1.0 d.

**The evidence is uniformly negative, and that IS the finding.** No shutdown
sequence, no panic, no MCE, no thermal trip, no EDAC, no PCIe/AER errors, no
corosync loss. An instant power-off leaving *zero* trace points below the OS.

**Prime suspect: mismatched non-ECC RAM.** Two mixed dual-rank SODIMMs — a Hynix
2667 and a G.Skill 2400, downclocked to 2400. Mixed-brand, mixed-spec, dual-rank
is a classic source of marginal instability, and HP business machines are picky
about non-HP memory. Critically the board has **no ECC**, so memory faults are
*structurally invisible* — which fits the all-negative evidence far better than
thermals, which would normally log throttling first.

**Still outstanding:** `memtest86+` is already installed with a GRUB entry. The
plan is several full passes, then bisect by running one DIMM at a time — memtest
can pass while RAM is still marginal under real load, so single-stick soak
testing is the stronger signal.

**Why nobody noticed:** the cluster self-heals every time, and
`HostUnexpectedReboot` notified nobody — at the time the ntfy topic had **no
subscribers**. (Subscribed since; delivery verified working 2026-08-22.)

---

## Stardate 2026-08-03 — "The Five Minute Downtime Window" (≈3 h)

LAN, WAN and DNS down ~2 h (vyosGateway lives on the `proxmox` host). etcd
degraded to 3/5 then 4/5 — **quorum never lost.** No data loss.

Triggered, ironically, by *new hardware alerting deployed four hours earlier*,
which revealed the `proxmox` host peaking at 95°C. Acting on that opened a
maintenance window. Four root causes, initially misdiagnosed as one cascade:

1. **An NVMe boot drive was removed in the belief it was a WiFi card.** A teardown
   video's framing survived three disconfirming observations — no antenna cables,
   no POST, boot-order changes useless. Resolved when Angelo's wife **read the
   label**.
2. **`vmbr1` bound to `enp3s0`, which no longer existed** after the real WiFi card
   came out → L2 blackhole → LAN-wide outage → `no route to host` between
   otherwise healthy k3s nodes. Identical unlabelled cables compounded it.
3. **kmaster02's etcd datastore unreadable** — `proto: wrong wireType`, 255 fatal
   restarts. Still not fully explained; broken data preserved.
4. **kube-vip circular dependency** — a half-dead master can squat VIP `.220`.

Restoration needed `pkill -f kube-vip` plus a manual `ip addr del` on the dead
master, because zombie containerd shims kept re-adding the VIP after
`systemctl stop k3s`. kmaster03 needed a full `qm stop`/`qm start` — `qm resume`
does **not** clear a stale block handle. Rejoining etcd needed only
`kubectl delete node` (k3s removes the member itself; no etcdctl required) and
`mv`, not `rm`, of the etcd directory.

**Key lesson, and the best one in this log:** when a hypothesis survives three
disconfirming observations, **the hypothesis is the problem**. A fresh observer
with nothing invested beat twenty years of experience.

---

## Stardate 2026-06-21 — "First Contact With the e1000e" (≈2.5 h)

All ingress down, four k3s nodes NotReady. Two compounding failures:

1. **node03m920's NIC TX hang** under sustained load — all four VMs on that host
   share one physical NIC via `vmbr0`, and high-traffic pods overwhelmed the TX
   descriptor ring. The driver's reset loop failed to recover. This was the first
   sighting of what would be properly identified on 2026-08-09.
2. **primecrunch had no CPU limit** and scaled to three replicas, consuming 100%
   of a 2-core node. Traefik, co-scheduled there, could not bind its management
   port → CrashLoopBackOff → all ingress down.

The tell was `kubectl get nodes` showing four NotReady nodes **all from the same
Proxmox host** — which is what first made the physical layer a suspect, and what
eventually motivated the zone-labelling work.

Fixed by adding `limits.cpu` to primecrunch, rebooting node03, and applying
`ethtool -K eno1 tso off gso off gro off` across all Proxmox hosts.

---

# Standing Orders

The durable lessons, stripped of story.

### Diagnosis

1. **When a hypothesis survives three disconfirming observations, the hypothesis
   is the problem.** Get a fresh pair of eyes. Read the label.
2. **Uniformly negative evidence is itself evidence.** No panic, no MCE, no
   thermal trip, no EDAC means the fault is *below* the OS — power delivery, or
   something structurally invisible like non-ECC memory.
3. **`journalctl --list-boots` + each boot's last line** turns "did it crash?"
   into a countable history. `Journal stopped` is clean; mid-sentence is a power
   loss.
4. **Cross-reference every host's boot list** before attributing a reset to one
   machine. Site-wide mains events masquerade as single-node faults.
5. **Check Longhorn volume health before blaming containerd.** An I/O hang on a
   dead volume presents as `CreateContainerError` and `context deadline exceeded`.
6. **Post-maintenance faults are physical until proven otherwise.** Reseat before
   condemning.
7. **Measure over comparable windows.** A 20-minute post-boot sample against a
   6-hour baseline manufactured an −8.2°C improvement that did not exist.

### Before touching hardware

8. **Never take three hosts down at once.** etcd (quorum 3 of 5) and corosync
   (quorum 4 of 6) each tolerate exactly two.
9. **Check physical placement manually.** Nothing in the stack is natively
   hypervisor-aware; three VMs on one host satisfy every anti-affinity rule.
10. **A host that stops answering while its VMs keep running is wedged, not
    dead.** Do not power-cycle it — that destroys the only evidence. Get console,
    capture `dmesg`, then reboot.
11. **Verify PCI/USB device paths before any remove/rescan.**

### Configuration traps

12. **Helm silently drops unknown values keys.** Traefik asked for `Local` and ran
    `Cluster` for months; `orphanAutoDeletion` leaked 142 GB. **Diff rendered
    against live after any chart major bump.**
13. **Longhorn registers disks by *path*, not device.** `nofail` needs
    `chattr +i` on the unmounted mountpoint or Longhorn will adopt the OS disk.
14. **Longhorn ignores the `volume.longhorn.io/number-of-replicas` PVC
    annotation.** A volume can claim 2 replicas and have 1.
15. **Orphan replica data skews the replica scheduler**, because Longhorn scores
    disks by available space. `replica-auto-balance` will not fix a cross-volume
    skew — there is no global capacity rebalancer.
16. **Node labels are GitOps-managed.** `kubectl label ... zone=` is silently
    reverted by Flux. Edit `cluster/topology/nodes.yaml`.
17. **`ethtool -K <dev> tso off gso off` must be made persistent** or it is lost
    on reboot.

### Monitoring

18. **Do not host your monitoring on the thing it monitors.** Prometheus ran
    single-replica on kmaster02 and died with the outage it should have reported.
19. **An alert nobody receives is not an alert.** `HostUnexpectedReboot` fired
    correctly for months into an ntfy topic with no subscribers. Resolved — but
    the lesson generalises: verify the *delivery* leg, not just the rule.
    `alertmanager_notifications_total{integration="webhook"}` and a
    `?poll=1&since=` poll against the ntfy topic are the two checks.
20. **One global threshold across heterogeneous hardware trains you to ignore
    alerts.** 70°C is unremarkable for node04's 65 W CPU and genuinely warm for a
    35 W T-series.
21. **Alert descriptions are triage instructions and must not over-claim.**
    `ProxmoxHostDown` said "every VM on this host is down" and was wrong for 29
    hours straight.

---

## Open threads

- 🔴 **node04 management plane wedged** (2026-08-17) — needs console + `dmesg`.
- 🔴 **node04 solo abrupt resets** — memtest86+ passes, then single-DIMM bisect.
- 🔴 **No alert on degraded Longhorn volumes** — a volume can sit at 1 replica silently.
- 🟡 **Per-host CPU temperature thresholds** — node04 cries wolf at its idle temp.
- 🟡 **node05's UNITEK enclosure** still negotiating USB 2.0 — needs a cable swap.
- 🟡 **`immich-db` has no WAL archiving** — no PITR, and a diverged replica cannot
  self-heal.
