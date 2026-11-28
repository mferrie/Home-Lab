# Incident Report: Longhorn Storage Disruption During Pi-hole PVC Troubleshooting

**Incident date:** November 27, 2026
**Status:** Recovery and remediation in progress
**Severity:** Multi-service infrastructure disruption
**Primary system involved:** Longhorn storage on the K3s cluster

## 1. Executive Summary

An initial storage-access problem affecting Pi-hole's configuration PVC prompted troubleshooting within the K3s cluster. During that troubleshooting, Longhorn volumes became detached, resulting in a broader storage disruption and affecting workloads beyond the original Pi-hole issue.

The recovery process exposed a separate, pre-existing configuration defect in the Nextcloud deployment: although a 50 GiB Longhorn PVC existed and was bound, the Nextcloud Deployment was configured to use an `emptyDir` volume instead. Consequently, Nextcloud was not actually using persistent storage for its writable application directories.

The original Longhorn storage issue and the Nextcloud persistence misconfiguration are distinct findings. The Nextcloud defect was discovered during the incident response; there is no evidence that it caused the initial Pi-hole problem or the Longhorn detachment.

The original Nextcloud data does not need to be recovered from the affected volume. The data is backed up elsewhere, and the old PVC, PV, Longhorn volume, and verified recovery copies are being preserved untouched.

## 2. Incident Timeline

### Initial symptom: Pi-hole storage access

Pi-hole was unable to access its configuration PVC over the network. This was the initial problem that prompted investigation.

The precise underlying cause of the access failure has not been established.

### Troubleshooting and escalation

Troubleshooting the Pi-hole storage-access problem led to operations involving the Longhorn storage layer. During this process, volumes became detached.

The disruption expanded beyond the original Pi-hole problem, resulting in widespread service interruption across the cluster.

The exact sequence of operations responsible for the detachment, and the precise mechanism by which the disruption propagated, remain unconfirmed.

### Storage recovery and investigation

Investigation identified a Longhorn volume in a detached state with unknown robustness. Its replica had stopped.

A snapshot was also found in an unusual state:

- `markRemoved: true`
- `readyToUse: false`
- The snapshot's children included `volume-head`

The original replica data was preserved. Copies of the relevant replica head and snapshot data were made, and checksums were compared against the originals. The hashes matched, verifying the integrity of the copies.

The affected storage was not discarded or treated as disposable.

### Secondary finding: Nextcloud was not using its PVC

During recovery, inspection of the Nextcloud Deployment revealed that its primary writable volume was configured as `emptyDir: {}`.

The Deployment mounted this ephemeral volume across its application directories, including:

- `/var/www/`
- `/var/www/html`
- `/var/www/html/data`
- `/var/www/html/config`
- `/var/www/html/custom_apps`
- `/var/www/tmp`
- `/var/www/html/themes`

A separate 50 GiB PVC named `nextcloud-nextcloud` existed in the namespace and was bound to a Longhorn PV, but the Deployment did not mount it.

This meant Nextcloud was operating with ephemeral storage despite an apparently provisioned persistent volume.

This was a latent deployment configuration defect, not an established cause of the original incident.

## 3. Impact

### Confirmed impact

- Pi-hole experienced a configuration-storage access problem.
- Longhorn volumes became detached during subsequent troubleshooting.
- The storage disruption affected multiple workloads and required broader recovery operations.
- Nextcloud was found to be configured with ephemeral application storage rather than the existing persistent volume.

### Scope not yet established

The complete list of affected workloads, exact outage duration, and precise sequence of storage operations responsible for the detachment have not been established in the available incident evidence.

These details should remain unconfirmed rather than be inferred.

## 4. Data Preservation and Recovery

The original Nextcloud files are backed up elsewhere and do not need to be recovered from the old Longhorn volume.

The following are being preserved:

- The original `nextcloud-nextcloud` PVC.
- Its bound PV, `pvc-df5ce36b-5961-4dc8-adda-c89326243ac4`.
- The corresponding Longhorn volume and its existing replica data.
- Recovery copies of the relevant replica files.

The recovery copies were checksum-verified against the originals.

The old volume is not being reused for the new Nextcloud installation. This avoids risking the preserved data and keeps the new deployment's storage lifecycle independent of the old volume.

## 5. Remediation Plan

### Longhorn and cluster storage

- Preserve the original volume and recovery copies.
- Verify Longhorn node, disk, replica, and volume health before further storage operations.
- Confirm that newly provisioned volumes receive the intended replica count and are placed on eligible storage nodes.
- Verify that affected workloads can access their volumes after recovery.

### Nextcloud

A clean Nextcloud installation is planned using a newly provisioned 50 GiB PVC named `nextcloud-data`.

The new claim will use the `longhorn-ssd` StorageClass and remain separate from the original `nextcloud-nextcloud` PVC.

The Helm chart will be configured to use the new claim through `persistence.existingClaim`. This is important because enabling chart-managed persistence without specifying an existing claim would cause the chart to attempt to create a PVC named `nextcloud-nextcloud`, colliding with the preserved old claim.

The intended configuration is:

```yaml
persistence:
  enabled: true
  storageClass: longhorn-ssd
  existingClaim: nextcloud-data
  accessMode: ReadWriteOnce
  size: 50Gi
  nextcloudData:
    enabled: false
```

The new PVC will be created and verified independently before changing the Nextcloud Helm values.

After deployment, persistence will be verified by confirming that the Deployment mounts the new PVC rather than `emptyDir`, and that uploaded files survive a Pod replacement.

Original files will be uploaded through Nextcloud's web interface rather than copying the old Nextcloud data directory directly. This allows Nextcloud to register and manage the uploaded files normally.

The existing Helm chart version will remain unchanged during this storage remediation to avoid introducing an unrelated application upgrade.

## 6. Root Cause and Contributing Factors

**Primary incident root cause: undetermined.**

The initial observed problem was Pi-hole's inability to access its configuration PVC over the network. Subsequent troubleshooting was followed by Longhorn volume detachment and a broader storage disruption.

Available evidence does not establish the precise cause of the initial access failure or the exact mechanism that resulted in the volumes becoming detached.

**Secondary configuration defect: confirmed.**

The Nextcloud Helm values had persistence disabled. The resulting Deployment used `emptyDir` for its writable application directories, even though a persistent volume claim existed in the namespace.

The presence of a bound PVC had therefore given a misleading impression that Nextcloud was using persistent storage.

## 7. Lessons Learned

### A PVC existing does not mean an application is using it

A bound PVC is not proof that a workload mounts it. The rendered Deployment or StatefulSet must be inspected to verify the actual volume source and mount paths.

### Validate rendered Helm manifests

Helm values alone are not sufficient evidence of the resulting workload configuration. Rendered manifests should be inspected before and after storage-related changes.

### Storage troubleshooting has a wider blast radius than the initiating workload

A problem affecting one application's storage can lead to operations against shared infrastructure. Changes to Longhorn volumes and replicas can affect workloads unrelated to the original symptom.

Storage operations should be staged and verified incrementally, with the state of affected volumes and replicas checked before proceeding.

### Preserve recovery evidence

Replica data and snapshot files should be preserved before attempting potentially destructive recovery operations. Checksum verification provides evidence that recovery copies match their source data.

### Test persistence, not just deployment health

A workload reporting `Running` or `Healthy` does not prove that its data is persistent. Persistence should be verified by inspecting mounts and testing survival across Pod replacement.

## 8. Follow-up Actions

- [ ] Establish the precise cause of Pi-hole's original configuration PVC access failure.
- [ ] Reconstruct the exact sequence of storage operations that preceded Longhorn volume detachment.
- [ ] Confirm the health and attachment state of all affected Longhorn volumes.
- [ ] Verify replica placement and health for newly provisioned volumes.
- [ ] Provision the independent `nextcloud-data` PVC.
- [ ] Update Nextcloud Helm values to use the new claim.
- [ ] Verify the rendered Deployment mounts the intended PVC.
- [ ] Verify Nextcloud data survives Pod replacement.
- [ ] Upload backed-up files through the Nextcloud web interface.
- [ ] Add persistent-volume mount verification to deployment review procedures.
- [ ] Document the expected storage-access architecture for Pi-hole and other stateful workloads.

---

**Final assessment:** The incident began as a Pi-hole configuration-storage access problem, escalated into a broader Longhorn storage disruption, and exposed an unrelated Nextcloud persistence defect. The original cause of the storage disruption remains unconfirmed. Recovery has prioritized preserving the original storage evidence and separating the new Nextcloud installation from the old volume.
