# bijouxlabs — Decision Register

The authoritative record of **architectural, storage, monitoring, workflow and
operational decisions** for the bijouxlabs cluster. If the cluster and this file
disagree, that's a bug in one of them — say so rather than silently picking a side.

**What belongs here:** choices. "We picked X over Y, and the cluster must respect it."
**What doesn't:** how to operate the thing (that's `docs/runbooks/`, gitignored),
the narrative of what went wrong (that's `docs/captains-log.md`), and discovered
facts or incident findings that nobody chose (those live in the agent memory
files under `.claude/projects/*/memory/`). When a memory note and a decision
cover the same ground, the memory note should point at `D-0NN` rather than
restate it.

**Status legend**

- **Locked** — build against this.
- **Provisional** — current working choice, may move with evidence.
- **Open** — explicitly undecided.
- **Superseded** — replaced by a later decision; text left intact.

**House rules**

1. Append at the end. Never renumber, never delete, never edit an entry into
   invisibility.

2. A *changed choice* = a new entry; the old one flips to Superseded with a
   pointer. A *factual correction* = a dated amendment in place.

3. The index below is a convenience. If it disagrees with an entry, **the entry
   wins** — fix the index.

4. Mandatory fields: title, Decision, Why, Status, date. Everything else optional.

5. **Every Locked entry cites what enforces it.** A decision states an intended
   rule; `**Enforced by:**` states what would actually stop the rule being broken —
   the manifest, chart value or admission control, named. If no such thing exists,
   say so: *"Convention only"*, or *"Nothing"*. Never leave the line off.

   Writing the citation is a **truth test**. If the evidence can't be found, the
   claim was never verified and shouldn't be Locked yet. This cluster has a
   specific weakness the test catches: things that **fail silent**. A Helm chart
   drops an unknown values key and runs the default for months. A PromQL rule
   names a metric that doesn't exist and returns empty, which looks exactly like
   all-clear. A Grafana sidecar watches only its own namespace, so a datasource
   ConfigMap in the wrong namespace simply never appears — no error anywhere.
   Every one of those was found by trying to write an enforcement line and
   failing to find the evidence.

   **"Nothing" is a claim too, and needs the same evidence as a citation.**
   Before writing it, search by *behaviour* — what would have to run at the moment
   the rule could be broken — not by the name you expect the guard to have.

6. **A citation naming a mechanism must have been observed working.** "Flux
   reapplies it" is a hypothesis until you break it by hand and watch it come
   back. Where an entry below says *verified*, that test was actually run.

---

## Index

| ID    | Decision                                                          | Status | Supersedes |
| ----- | ----------------------------------------------------------------- | ------ | ---------- |
| D-001 | Masters run storage and control plane only                        | Locked | —          |
| D-002 | The dead-man's switch is external and never routes through ntfy   | Locked | —          |
| D-003 | Monitoring alerts on its inability to record, not just on liveness | Locked | —          |
| D-004 | Logs are pushed outbound to an in-cluster Loki                    | Locked | —          |
| D-005 | The log collector has no node exclusions                          | Locked | —          |
| D-006 | The Prometheus TSDB is disposable — recreate, never repair        | Locked | —          |
| D-007 | An alert rule is not Locked until fired against a known positive  | Locked | —          |
| D-008 | node04g4800's future — repair, repurpose or retire                | Open   | —          |

---

### D-001 — Masters run storage and control plane only

**Decision:** All five masters carry
`node-role.kubernetes.io/control-plane=true:NoSchedule`, declared in git for every
master rather than inherited from how each node happened to be joined. Longhorn
(`csi-attacher`, `csi-provisioner`, `instance-manager`, `share-manager`) and the
k3s system components (`coredns`, `metrics-server`, `local-path-provisioner`)
carry explicit tolerations and are *intended* to stay. Application workloads are
not.

**Why:** kmaster01/04/05 were joined with the taint and kmaster02/03 were not.
k3s does not taint servers by default — it only happens with `--node-taint` at
join time — and the taint was never declared anywhere, so every rebuild was a
coin flip. The drift is invisible: an untainted master looks identical to a
tainted one until the scheduler quietly puts Traefik on it. On 2026-08-25
kmaster02 was running traefik, homepage, goldilocks-dashboard and
cert-manager-webhook. The masters also hold every Longhorn NVMe disk, so
contention there is contention with cluster storage.

**Consequences:** A workload that must run on a master needs an explicit
toleration and a reason. `NoSchedule` does not evict what is already running —
displacing existing pods is a separate, deliberate step.

**References:** `cluster/topology/nodes.yaml`.

**Enforced by:** `cluster/topology/nodes.yaml` + Flux. Each Node carries
`kustomize.toolkit.fluxcd.io/ssa: merge`, so Flux owns `spec.taints` and
reapplies it. **Verified 2026-08-25** by running
`kubectl taint node kmaster03 node-role.kubernetes.io/control-plane-` and
watching a single `flux reconcile` put it back. This is real enforcement, not
convention — a hand-removed taint returns on the next sync.
**Status:** Locked. 2026-08-25.

---

### D-002 — The dead-man's switch is external and never routes through ntfy

**Decision:** The `Watchdog` alert routes to the `deadman` receiver, which pings
an external Healthchecks.io endpoint every 5 minutes. That external service
alerts when the pings **stop**. No liveness signal may be delivered by anything
running inside this cluster.

**Why:** ntfy and uptime-kuma are both in-cluster. A full-cluster loss paged
nobody on 2026-08-09 and ran ~13h undetected, because the thing meant to raise
the alarm died with the thing it was watching. The logic here is inverted
against every other receiver: we are not notifying on a problem, we are proving
liveness, and silence is the signal.

**Consequences:** The heartbeat URL is a credential — anyone holding it can keep
the check green and suppress the very alert it exists to raise. It is a mounted
secret consumed via `url_file`, never an inline URL, because this repo is public
and `alertmanager.config` renders verbatim into a Secret. If `repeat_interval`
changes, the external check's period must change with it; keep period ≥ 3× the
ping rate.

**Known gap:** This proves Prometheus is *running*. It cannot prove Prometheus is
*correct* — see D-003, which exists precisely because a half-dead Prometheus held
this check green for 14.5 hours.

**References:** `apps/monitoring/helmrelease.yaml` (`receivers.deadman`, the
`Watchdog` route, which must stay first in `route.routes`);
`apps/monitoring/secrets/deadman-secret.sops.yaml`.

**Enforced by:** The routing itself — `Watchdog` matches the `deadman` route
first, so it cannot fall through to the ntfy receiver. That is real for current
behaviour but does **not** prevent a future edit; nothing rejects a config that
reorders those routes. The external check's own Period and Grace live in
Healthchecks.io, outside this repo, and nothing here can assert what they are.
**Status:** Locked. 2026-08-10, recorded 2026-08-25.

---

### D-003 — Monitoring alerts on its inability to record, not just on liveness

**Decision:** Prometheus must alert on losing the ability to *record* —
`PrometheusTSDBWriteFailing` on WAL write failures, `PrometheusNotIngesting` on
sample ingestion stopping — separately from anything that checks it is alive.

**Why:** On 2026-08-24 Prometheus's PVC went read-only (ext4 journal abort) and
it kept running for 14.5 hours. It was alive enough to hold the dead-man's
switch green (D-002) while emitting **false** `KubeletDown` alerts and — far
worse — a **false all-clear** on `HostManagementPlaneWedged` while node04 was
still wedged. A liveness check cannot catch this by construction: it asks "is
Prometheus running?" and Prometheus *was* running. `PrometheusTSDBWriteFailing`
would have fired in 5 minutes instead of 14.5 hours.

**Consequences:** A burst of unrelated alerts resolving within a few minutes of
each other means the pipeline died, not that the fleet recovered. Check
`kubectl -n monitoring get pods` before believing any ✅.

**References:** `apps/monitoring/rules/cluster.yaml`
(`bijouxlabs.selfmonitoring`).

**Enforced by:** The rules themselves, loaded by the Prometheus Operator from
the `PrometheusRule` CR. They fire or they don't — there is no separate guard,
and nothing objects if a future edit removes them. Both metric names were
verified to exist on the live instance before the rules were written, per D-007.
**Status:** Locked. 2026-08-25.

---

### D-004 — Logs are pushed outbound to an in-cluster Loki

**Decision:** Every Proxmox host runs `rsyslog` forwarding **RFC5424 over TCP**
to a MetalLB endpoint in front of Grafana Alloy, which writes to a Loki running
in this cluster. Hosts push; nothing pulls from them. The forwarding queue is
disk-assisted so a host buffers and replays rather than dropping.

**Why:** node04g4800's management plane wedged on 2026-08-17 and stayed
unreachable for 8 days. Its failure mode drops every **new inbound** connection
while established and **outbound** traffic keeps flowing — corosync never missed
a beat and ARP still answered in 0.67ms. Anything that pulls would have gone
blind; a push kept working. Three separate root causes were permanently lost to
missing logs on 2026-08-25 alone.

RFC5424 rather than rsyslog's RFC3164 default because 3164 carries **no year and
no timezone**, and this fleet logs UTC while its admin reads SAST. That ambiguity
is not cosmetic — it made the 2026-08-24 timeline take three passes to read
correctly.

**Consequences:** PVE 8.4 ships no rsyslog at all (journald only), so this
installs a package on the hypervisors. Syslog flattens journald's structured
fields — you keep host/tag/facility/severity, you lose `_SYSTEMD_UNIT` as a
queryable label. `systemd-journal-upload` is not an alternative: it speaks to
`systemd-journal-remote`, which Alloy does not implement.

**Known gap:** Loki lives in the cluster it monitors, so this does **not** solve
a total-cluster loss — that remains D-002's job. It solves the far more common
case of one host or one component going dark while the cluster is fine.

**Revisit trigger:** If structured journal fields are needed, replace rsyslog
with Alloy on the host using `loki.source.journal`.

**References:** `apps/logging/`, `docs/runbooks/proxmox-syslog-to-loki.sh`
(gitignored).

**Enforced by:** Nothing on the host side. `rsyslog` forwarding is a file at
`/etc/rsyslog.d/60-loki.conf` placed by a script; the hosts are not under
GitOps, so nothing detects or repairs its removal, and nothing notices a host
that silently stops shipping. **This is the weakest link in the register.** The
honest fix is an alert on `absent_over_time()` for each expected hostname —
not yet written.
**Status:** Locked. 2026-08-25.

---

### D-005 — The log collector has no node exclusions

**Decision:** The Alloy DaemonSet tolerates every taint (`operator: Exists`, no
key) and runs on all 14 nodes, masters included. Coverage gaps are not an
acceptable trade for tidiness.

**Why:** On first deploy Alloy landed on 11 of 14 nodes — kmaster01/04/05 were
tainted and it had no toleration. **kmaster04 lives on node04g4800**, the exact
host whose unexplained wedge is the reason the stack exists. A collector with
blind spots on the boxes you most need to debug is worse than useless, because
absence of logs reads identically to absence of problems. This is the same
fail-open shape as a PromQL rule naming a metric that doesn't exist.

**Consequences:** This is a deliberate exception to D-001, and the only kind that
should be granted lightly: an observer, not a workload. `operator: Exists` with
no key is chosen over naming the control-plane taint so that a node tainted for
some *future* reason cannot silently drop out of coverage.

**References:** `apps/logging/helmrelease-alloy.yaml` (`controller.tolerations`).

**Enforced by:** The toleration in the HelmRelease. Nothing asserts that the
DaemonSet's ready count equals the node count, so a regression would be visible
only by looking. An alert comparing `kube_daemonset_status_number_ready` against
node count would close this — not yet written.
**Status:** Locked. 2026-08-25.

---

### D-006 — The Prometheus TSDB is disposable — recreate, never repair

**Decision:** Prometheus metrics are treated as regenerable. Its volume uses
`longhorn-ephemeral`: 2 replicas for availability, **no backups**. When the
volume is damaged, the response is to delete the PVC and let it reprovision, not
to `e2fsck` and salvage.

**Why:** Replicas buy two separable things — surviving the loss of a host, and
not losing the data. Prometheus wants the first and not the second. Longhorn
snapshots are copy-on-write, so a snapshot pins blocks Prometheus has already
expired: on 2026-08-22 the 50Gi volume held **7.76 GiB of live data against 92.8
GiB of stale backup snapshots**. A snapshotted Prometheus volume can only grow.
On 2026-08-24, when the filesystem aborted, recreating restored alerting in two
minutes; fsck would have taken longer and still risked an inconsistent TSDB that
was force-read-only mid-write.

**Consequences:** Metric history does not survive a volume incident, and that is
accepted. Anything that must survive belongs in Grafana (dashboards) or in a
recording rule exported elsewhere — not in the TSDB alone.

**References:** `cluster/longhorn/storageclass-ephemeral.yaml`;
`apps/monitoring/helmrelease.yaml` (`prometheusSpec.storageSpec`);
`.claude/.../project_prometheus_ext4_journal_abort.md`.

**Enforced by:** The absence of backups, which is genuine enforcement by
construction — `recurringJobSelector` names a group no `RecurringJob` targets, so
there is nothing to restore *from*, and "repair it" is not an option anyone can
quietly take. The `reclaimPolicy: Delete` on the class means deleting the PVC
really does remove the volume rather than leaving an orphan.
**Status:** Locked. 2026-08-25.

---

### D-007 — An alert rule is not Locked until fired against a known positive

**Decision:** Before an alert rule is trusted, (a) every metric it names must be
confirmed to exist on the live instance, and (b) the expression must be run in
both directions — confirmed silent when it should be, and confirmed matching
when the condition is inverted.

**Why:** A PromQL rule naming a metric that doesn't exist returns empty, which is
**indistinguishable from all-clear**. Three dead rules were found in a single day
(2026-08-22). Rules fail open, and a rule that has never matched anything is
indistinguishable from a rule that is working.

Part (b) is not theoretical padding. Writing D-003's rules, all four candidate
metrics existed — the check in part (a) passed — and the expression was still
wrong: `prometheus_tsdb_head_samples_appended_total` splits on a `type` label,
and the `{type="histogram"}` series sits at 0 forever because native histograms
are unused here. The bare `rate(...) == 0` matched it and would have fired
**permanently**. Only running the expression caught it. A permanently-firing
alert is worse than no alert, because it teaches you to ignore the channel.

**Consequences:** `sum()` in that rule is load-bearing, not cosmetic. Rules
authored offline against documentation are Provisional at best until run.

**References:** `.claude/.../reference_promql_rules_fail_open.md`;
`apps/monitoring/rules/cluster.yaml`.

**Enforced by:** Convention only. Nothing in CI evaluates these rules — there is
no `promtool check rules` step, and no test that a rule has ever produced a
non-empty result. This is a discipline, and it will rot exactly as fast as it is
neglected.
**Status:** Locked. 2026-08-25.

---

### D-008 — node04g4800's future — repair, repurpose or retire

**Decision:** Undecided. Recorded so the choice is made deliberately rather than
by exhaustion.

**Why it's open:** node04 has two distinct, unexplained failure modes — silent
hard resets, and a management-plane wedge that **survived a full power cycle** on
2026-08-25 (ARP answers in 0.67ms while every TCP port silently drops, including
ports with no listener; a healthy host RSTs those). It is also the highest
blast-radius host in the fleet at 5 k8s nodes, and the only 65W i5-8500 among
35W T-series siblings. Retiring it and moving its RAM into node05 has been raised.

**What has to happen before this can close:** the wedge's cause has to be known.
The fault reproduces on every boot, so the evidence is no longer perishable and
`init=/bin/bash` at the console is now both safe and password-free. Until someone
reads the ruleset off that box, "repair" and "retire" are being chosen between on
no evidence.

**Not blocking:** the cluster tolerates node04 being down — etcd 5→4, corosync
6→5, zero Longhorn replicas on any of its VMs.

**References:** `.claude/.../project_node04_mgmt_plane_wedge.md`,
`.claude/.../project_node04_silent_resets.md`.

**Status:** Open. 2026-08-25.

---
