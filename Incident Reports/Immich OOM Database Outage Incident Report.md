# Immich OOM / Database Outage Incident Report

Oct 12, 2026 · @Matt Ferrie

## Summary

On August 8, 2026, the Immich photo management stack (namespace `immich`) became unavailable due to a cascading failure that began with a hardware fault on node `pi-4`. The CloudNative-PG-managed PostgreSQL primary (`immich-database-1`) entered CrashLoopBackOff after its underlying storage was forced read-only by the kernel in response to failing media on the USB flash drive backing that Longhorn disk. The database outage in turn stalled an in-progress `immich-server` Deployment rollout, leaving two full ReplicaSets running simultaneously and doubling memory pressure on an already-overcommitted node. The incident was resolved by rebuilding the affected Longhorn volume from a healthy replica on a second node and rescheduling workloads off the failing node. No data was lost. Total unhealthy-database window was approximately 3.5 hours (14:13 to \~17:39 local time), with `immich-server` remaining degraded roughly an hour longer until the node was cordoned.

## Timeline

| Time (Aug 8, 2026) | Event |
| --- | --- |
| 14:13 | `immich-database-1` pod starts normally |
| \~14:13–17:36 | Kernel logs record `critical medium error` read failures on the physical USB flash drive, across multiple Longhorn virtual device nodes backed by it |
| \~17:36 | Node `pi-4` goes `NodeNotReady`; kubelet stops posting status |
| 17:51 | Postgres restart attempt fails: `chmod ... pgdata: read-only file system` — the volume's ext4 filesystem has entered `emergency_ro` |
| 17:51–20:30s | `immich-database-1` CrashLoopBackOff continues (11+ restarts); `immich-server` rolling update stalls because new pods can't pass readiness without a working database, leaving old and new ReplicaSets both running |
| Investigation start | `kubectl logs --previous` identifies the read-only filesystem error as the proximate cause |
| Investigation | `smartctl`/`lsusb` trace the fault through Longhorn's virtual iSCSI device names down to the actual physical disk: a Silicon Motion SM2320-based USB flash drive |
| Investigation | `kubectl get replicas.longhorn.io` confirms the volume has a second, healthy replica on node `dell-debian`, with overall volume `robustness: healthy` |
| Recovery | A rescue pod mounts the PVC directly; filesystem is confirmed readable but not writable (`emergency_ro` persists); full `pgdata` copied off via `tar` as a safety backup |
| Recovery | Bad replica on `pi-4` deleted from Longhorn (`kubectl delete replicas.longhorn.io ...`); Longhorn rebuilds a new replica from the healthy `dell-debian` copy in seconds |
| Recovery | `immich-database-1` pod recreated; comes up `1/1 Running` with zero restarts against the rebuilt volume |
| Recovery | `immich-server` pods continue restarting post-fix; traced to node `pi-4` itself being unresponsive (SSH hangs, kubelet not posting status, DNS failures) under resource exhaustion from running the full Immich stack plus unrelated workloads (Nextcloud, Longhorn management, Pi-hole) with no resource requests set |
| Recovery | Node `pi-4` power-cycled, comes back reachable; operator cordons `pi-4` |
| Recovery | `immich-server`'s stale ReplicaSet manually scaled to 0; all Immich workloads reschedule onto `dell-debian`; stack reports healthy |

## Root cause

Two independent root causes combined to produce the outage.

**1. Failing physical storage underneath the database's Longhorn volume.** The disk identified via `lsusb` as a Silicon Motion SM2320-based USB flash drive developed genuine medium-level read errors (`critical medium error`, confirmed in kernel logs across sectors 0 and 2097024 on two separate Longhorn-exposed device nodes backed by the same physical disk). This is consistent with consumer-grade USB flash NAND under a workload it was never designed for: PostgreSQL's constant small, synchronous writes (WAL fsyncs). The kernel's ext4 driver correctly responded by forcing the filesystem into `emergency_ro` to prevent further corruption, which is what directly broke Postgres's ability to start (`chmod ... pgdata: read-only file system`).

**2. Unrelated resource overcommitment on the same node.** Node `pi-4` (a Raspberry Pi 4, 4 GB RAM) was running the entire Immich stack (database, server ×2 during the stalled rollout, machine-learning, valkey) alongside unrelated workloads — Nextcloud, Pi-hole/unbound, and Longhorn's own management components — with no CPU or memory requests/limits set on any of them. This left the Kubernetes scheduler unable to reason about actual resource needs, and the node became unresponsive under memory pressure once the database crash loop and stalled rollout compounded the load. This second issue was independent of the disk failure and persisted after the storage problem was fixed, requiring a separate remediation (cordon + reschedule).

## Impact

- **Availability**: Immich was fully unavailable for the duration of the database outage (\~3.5 hours) and remained degraded for roughly an hour afterward while `immich-server` pods crash-looped on the overcommitted node.
- **Data loss**: None. The Longhorn volume's second replica on `dell-debian` was in sync and healthy throughout, and a full filesystem-level backup of the data directory was additionally taken as a precaution before any recovery action was attempted.
- **Blast radius**: Contained to the `immich` namespace. Other workloads on `pi-4` (Nextcloud, Pi-hole/unbound, homepage) were not reported as affected during this incident, though they share the same underlying resource-overcommitment risk.
- **User-facing**: Photo uploads, browsing, and machine-learning features (face/object recognition) were unavailable for the full outage window.

## Resolution

1. Traced the CrashLoopBackOff to a read-only filesystem error via `kubectl logs --previous`, and from there to physical medium errors on the USB flash drive backing the Longhorn volume (confirmed via kernel logs, `smartctl`, and `lsusb`).
2. Confirmed via `kubectl get replicas.longhorn.io` and the volume's `robustness: healthy` status that a second, unaffected replica existed on node `dell-debian`.
3. Mounted the affected PVC into a standalone rescue pod (bypassing CNPG) to confirm the data directory's structure was intact, and took a full `tar` backup of it as a safety net before any further action.
4. Deleted the degraded replica on `pi-4` from Longhorn, triggering an automatic rebuild from the healthy `dell-debian` replica (completed in seconds).
5. Recreated the `immich-database-1` pod; it started cleanly with zero restarts against the rebuilt volume.
6. Diagnosed continued `immich-server` restarts as a separate node-level resource exhaustion issue on `pi-4`, confirmed via `kubectl describe node` (unknown `MemoryPressure`/`Ready` conditions, kubelet not posting status) and direct observation (SSH and DNS unresponsive).
7. Power-cycled `pi-4`, cordoned it to prevent further scheduling, manually scaled the stale `immich-server` ReplicaSet to 0, and allowed workloads to reschedule onto `dell-debian`.
8. Confirmed `immich-database-1` at `1/1 Running`, `immich-server` reduced to a single healthy ReplicaSet, and the full stack reporting healthy on `dell-debian`.

## Follow-up actions

| Action | Status | Owner |
| --- | --- | --- |
| Set CPU/memory requests and limits on all Immich components (server, machine-learning, valkey) and the CNPG `Cluster` | Drafted as Helm values / `pg.yaml` changes | Operator |
| Add soft node anti-affinity steering Immich workloads away from `pi-3` (950 MB RAM, too small to host any component) | Drafted alongside resource changes | Operator |
| Stand up CNPG scheduled backups (WAL archiving + daily `ScheduledBackup`) via a local MinIO instance on `dell-debian`, credentials stored as a `SealedSecret` | Manifests drafted (`pg.yaml` backup block, `minio-backups.yaml`); pending apply, bucket creation, and a verified test backup | Operator |
| Replace or retire the failing USB flash drive on `pi-4` as Longhorn-backed storage | Not started | Operator |
| Consider `instances: 2` on the CNPG `Cluster` for automatic primary/replica failover, independent of Longhorn-level replication | Not started | Operator |
| Mirror backups to storage physically separate from `dell-debian` (the same node the Longhorn rescue depended on) | Not started | Operator |
| Back up the sealed-secrets controller's private key outside git, so existing `SealedSecret`s remain decryptable if the controller is ever rebuilt | Not started | Operator |
