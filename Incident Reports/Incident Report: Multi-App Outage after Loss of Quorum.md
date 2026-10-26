Incident Report: Multi-App Outage after Loss of Quorum
Note: All times are given in UTC

Date: October 10, 2026
Environment:
		k3s server cluster (hostnames: dell-debian, pi-3, pi-4; dell-debian is control plane)
		Longhorn v1.1.12
		ArgoCD
		CloudNativePG v1.30.0
Final Status: Service restored, no data loss

Summary:
Two of three k3s nodes (pi-3 and pi-4) were shut down to reconfigure cooling. When pi-4 fully booted, its Longhorn instance manager pod never got a network sandbox, preventing a volume engine from starting on that node. This resulted in Immich crashing and Mealie’s database being degraded. Deleting and restarting the failed sandbox and engine restored two of the four volumes, while the remaining volumes remained in the creating state. A Postgres database required a long process to clear up, including manual cleanup of corrupted Longhorn objects. No data was lost, and a copy of the Postgres replica was taken prior to remediation.

Impact:
    • Services:
        ◦ Immich: complete loss of service; the server crash-looped due to failure of its database and Valkey instance to reattach
        ◦ Mealie: Postgres volume failed to completely attach to the pod, resulting in partial degradation
    • Duration: Mealie’s Postgres volume detached at 15:04 UTC (10:04 AM local time) and remained detached for another five hours. The other volumes recovered sooner.
    • Data: No loss or corruption observed. All pods stayed running on dell-debian through the incident.

Time Table:
17:59 – 18:21: Longhorn manager logs show pi-4 instance manager stuck in starting state with a stale IP; engines for immich server and Mealie Postgres volumes fail to sync every 30 seconds

18:15 – 18:16: Two snapshot-controller tickets appear on the Postgres volume

18:30: The pi-4 instance manager pod is found pending with no IP. It is deleted and recreated, allowing the Immich server and Mealie volumes to attach

18:45: The pi-4 Longhorn manager pod is restarted. No change for the stuck volumes.

19:00: Valkey deployment scaled down to zero replicas and its volume goes detached

19:05: CNPG hibernation is set on the Postgres cluster and reports WaitingForHealthy

19:26: Replica data copied to /root/pg-replica-backup on dell-debian. Two empty snapshots were patched to remove finalizers. Two stale attach tickets removed. Volume reports healthy.

19:32: CNPG operator scaled back to 1. Postgres pod starts successfully, restoring services


Root Cause Analysis:

pi-4 instance manager never recovered after reboot
The instance manager pod on pi-4 stayed Pending with no IP and PodReadyToStartContainers: False, meaning its pod sandbox was never recreated on startup. Longhorn still held the stale IP in its InstanceManager object and reported the state as starting indefinitely. Engines for any volume attached to pi-4 could not start. Deleting the pod fixed the problem.
The reason the sandbox failed to recreate was not found.

Postgres and Valkey volumes stuck in creating
Both volumes remained in the creating state with stopped engines and unsatisfied attach tickets, while healthy replicas ran on dell-debian. The first stuck state is not fully explained.
The evidence shows the following:
    • Valkey cleared once its pod was removed, releasing its single attach ticket
    • The Postgres volume additionally carried two snapshot-controller tickets created while it was stuck. The snapshots before them could not be deleted due to the absence of a running engine, which was unable to start due to the pending tickets.
    • CloudNativePG recreated the database pod each time it was deleted, which kept re-requesting the attach operation that was impossible to satisfy. CNPG hibernation could not break the deadlock because the operator waits for the cluster to report healthy

Contributing Factors:
    • Every volume’s data lived on dell-debian. Volumes request two replicas but only one was placed, and pi-4 received no replicas despite availability.
    • Nodes were shut down without draining
    • No Longhorn backup target is configured
    • ArgoCD auto-sync can revert manual changes, so it was paused during recovery

Resolution:
    • Deleted the stuck pi-4 instance manager pod, which Longhorn successfully recreated. The Immich server and Mealie volumes attached.
    • Scaled Valkey to zero to release the attach ticket. The volume detached.
    • Paused ArgoCD auto-sync and self-healing, scaled CNPG operator deployment to zero, and copied the replica directory on dell-debian to /root/pg-replica/backup.
    • Removed finalizers from two empty snapshots that failed to fully create, then removed two stale attach tickets from Longhorn VolumeAttachment. The volume detached.
    • Removed the hibernation annotation, scaled the operator back up to 1, and allowed Postgres to start and recover.

Manual interventions to be aware of: stripping snapshot finalizers and patching a Longhorn VolumeAttachment bypass Longhorn’s normal cleanup process. Nothing has gone wrong as a result, but this was a judgement call based on object state, not documented procedures.

Successes:
    • Replicas remained healthy on dell-debian, so no data was at risk
    • The Longhorn manager logs pointed to the instance manager clearly
    • The Postgres replica was backed up before the riskiest step
    • Changes were easy to revert in case of mistakes
      
Difficulties:
    • Both nodes were shut down without draining, and one was left with a stranded Longhorn pod.
    • Several fixes failed before the working one. Hibernation looked like a clean fix but was blocked by the operator's health requirement.
    • A single copy of each volume on a single disk, with no backup, turned a hardware swap into a data-risk event.

Recurrence Prevention:
    • Drain a node prior to planned shutdown
    • Configure a Longhorn remote backup and configure recurring backups
    • Determine why the second replica was never placed and why pi-4 holds zero replicas (disk monitor warnings in the pi-4 manager pod should be useful)
    • Check the k3s-agent journal on pi-4 around the time of reboot for sandbox or CNI-related errors to determine why instance-manager was left without a network

Recap of Lessons
    • With Longhorn, a node that reports as Ready to Kubernetes may still have an unusable instance manager.
    • CNPG hibernation only takes effect once the cluster reports healthy, so it cannot rescue a database whose volume remains unattached.
    • Attach tickets and snapshot deletions can enter deadlock when an engine cannot start. Diagnose by looking at VolumeAttachment tickets and snapshot logs for errors.
