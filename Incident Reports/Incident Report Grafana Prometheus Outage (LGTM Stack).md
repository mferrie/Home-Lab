# Incident Report: Grafana/Prometheus Outage (LGTM Stack)

Oct 12, 2026 · @Matt Ferrie

## Summary

The Grafana Prometheus datasource in the self-hosted LGTM stack (k3s, 3 nodes) became unreachable, while Grafana itself continued to load normally. The outage was caused by the `prometheus-server` pod entering `CrashLoopBackOff` after its 8Gi PersistentVolumeClaim filled to capacity, which triggered a disk-full panic during Write-Ahead Log (WAL) replay on startup. Several unrelated issues were investigated in parallel before the root cause was identified, including a router WireGuard failure, a MetalLB speaker bind error, and a Longhorn node taint — none of which caused the outage, though the MetalLB and Longhorn issues were real, independent problems worth tracking. Service was restored by enabling volume expansion on the `longhorn-ssd` StorageClass and resizing the PVC from 8Gi to 16Gi, with a size-based retention cap added afterward to prevent recurrence.

## Timeline

| Time (approx.) | Event |
| --- | --- |
| Jul 10, 22:18 UTC | `prometheus-server` pod's PVC approaches full capacity; MetalLB `speaker-2t69q` logs an unrelated transient bind failure on `dell-debian` (192.168.0.10:7946), contributing to 81 restarts over the following day |
| Jul 11, \~evening | Grafana's Prometheus datasource begins failing with "endpoint not reachable"; Grafana UI itself remains functional |
| Jul 11, 17:48 | `prometheus-server` pod rescheduled to `pi-4`; Longhorn briefly reports a Multi-Attach error before successfully attaching the volume |
| Jul 11 (session start) | Investigation begins: router WireGuard outage considered as a possible cause; ruled out after confirming cross-node `ping` succeeds and k3s uses flannel in-process (no separate pods), not Traefik, for east-west traffic |
| During investigation | MetalLB speaker pods cycled (`kubectl delete pod -l component=speaker`) to rule out stale leader-election state; confirms only 2 of 3 speakers return |
| During investigation | Discovered a Longhorn disk had been manually disabled on `pi-3` (SD card protection), which excluded that node from DaemonSet scheduling via an auto-applied taint — a real but separate issue from the outage |
| During investigation | `prometheus-server` found in `CrashLoopBackOff` (1/2 Ready, 11+ restarts); `kubectl describe pod` and container logs retrieved |
| Root cause found | Previous container logs show a panic: `write /data/chunks_head/000192: no space left on device`, occurring during WAL replay |
| Jul 11, 18:02 | PVC usage confirmed at 8.02Gi / 8Gi on the `longhorn-ssd` StorageClass |
| Resolution | `longhorn-ssd` StorageClass patched to `allowVolumeExpansion: true`; PVC resized to 16Gi; pod restarted and came up healthy |
| Resolution | Helm values updated with `server.persistentVolume.size: 16Gi` and `server.retentionSize: "14GB"`; `helm upgrade --reuse-values` applied successfully |

## Root cause

Prometheus was deployed with only a time-based retention policy (`--storage.tsdb.retention.time=15d`) and no size-based cap. Disk usage grows independently of that setting — it tracks scrape volume and label cardinality — so total usage crept upward over time with no mechanism to stop it before hitting the PVC's fixed 8Gi limit.

Once the volume filled, the `prometheus-server` container could start and begin replaying its WAL, but panicked the moment it tried to write a new chunk:

```
panic: write /data/chunks_head/000192: no space left on device
```

This produced a crash loop: each restart replayed the WAL partway, then panicked again on the same write, which is why the pod showed `1/2 Ready` with the `prometheus-server-configmap-reload` sidecar healthy throughout. The sidecar has no `/data` mount and was unaffected.

The crash was coincidental in timing with two unrelated events (a router WireGuard failure and a manual Longhorn disk change on `pi-3`), which initially pointed investigation toward networking rather than storage.

## Investigation notes (ruled-out and parallel issues)

| Lead | Finding | Status |
| --- | --- | --- |
| Router WireGuard VPN server stopped working around the same time | k3s east-west Service traffic does not traverse the router's WireGuard process; cross-node `ping` succeeded, confirming basic L3 connectivity was intact | Ruled out — unrelated coincidence |
| Suspected router "forgot how to route" | Internet access and internal DNS resolution continued working, which is inconsistent with a blanket routing failure | Ruled out |
| Traefik suspected as the service-to-service routing layer | Traefik is the ingress controller for external traffic only; internal Service-to-Service calls go through CoreDNS, kube-proxy, and the CNI, never Traefik | Clarified, not a factor |
| k3s CNI (flannel) health | k3s runs flannel in-process rather than as separate pods, so its absence from `kube-system` pod listings is expected and not a fault | Not a factor |
| MetalLB speaker instability (`speaker-2t69q`, 81 restarts) | Caused by a transient `bind: cannot assign requested address` error on `192.168.0.10:7946`; the IP is now stable and bound. Speaker pods were cycled to force clean leader re-election | Resolved; underlying one-time cause not conclusively identified (no retained logs for that window) |
| MetalLB speaker DaemonSet showing 2/3 pods | Caused by `pi-3` being excluded from scheduling after a taint was applied when its Longhorn disk was manually disabled | Understood; expected behavior given the disk change, not an outage cause |
| Longhorn disk disabled on `pi-3` | Intentional change made to protect the node's SD card from wear; excluded `pi-3` from DaemonSet scheduling (including MetalLB speaker) | Expected side effect — no action needed unless `pi-3` needs to participate in future workloads |

## Resolution

1. Confirmed the `prometheus-server` PVC (`longhorn-ssd` StorageClass) was at 8.02Gi / 8Gi used.
2. Found `allowVolumeExpansion` was set to `false` on the `longhorn-ssd` StorageClass; patched it to `true`:

   ```
   kubectl patch storageclass longhorn-ssd -p '{"allowVolumeExpansion": true}'
   ```
3. Resized the PVC from 8Gi to 16Gi and restarted the pod so it could pick up the larger volume.
4. Prometheus came up successfully, skipping the one corrupted chunk file it had already detected during WAL replay, and the Grafana datasource reconnected.
5. Updated the Helm values file for the `prometheus-community/prometheus` release to persist the fix:

   ```yaml
   server:
     persistentVolume:
       size: 16Gi
     retentionSize: "14GB"
   ```
6. First `helm upgrade` attempt failed with a field-ownership conflict (`conflict with "kubectl-patch" using v1: .spec.resources.requests.storage`), caused by the earlier manual `kubectl patch` claiming ownership of that field. Resolved by re-running with `--reuse-values` against the updated values file, which applied cleanly.

## Follow-up actions

- [x] Enable `allowVolumeExpansion` on the `longhorn-ssd` StorageClass
- [x] Resize `prometheus-server` PVC to 16Gi
- [x] Add `server.retentionSize: "14GB"` to Helm values so Prometheus self-prunes before the volume fills again
- [ ] Monitor PVC usage growth over the next 1–2 weeks (`kubectl get pvc prometheus-server -n lgtm`) to confirm 16Gi with a 14GB retention cap gives adequate headroom
- [ ] Consider alerting on PVC usage (e.g. a Prometheus self-monitoring rule) so a volume approaching capacity is caught before it causes an outage, rather than discovered after a crash
- [ ] Decide whether `pi-3` should rejoin general DaemonSet scheduling (e.g. MetalLB speaker) now that its Longhorn disk is intentionally disabled, or whether a permanent node selector/toleration should formalize that exclusion
- [ ] No action needed on the router/WireGuard issue for this incident, but worth separately investigating why the VPN server stopped responding, since it was never conclusively explained
