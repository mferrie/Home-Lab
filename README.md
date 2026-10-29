# Multi-Architecture K3s Edge Cluster & GitOps Infrastructure

## Project Overview
A declarative, multi-architecture Kubernetes (K3s) cluster managing ~24 stateful and stateless services across a hybrid node pool (ARM64 edge devices and x86_64 compute). Designed for high resource density within a 25GB RAM footprint, leveraging automated GitOps pipelines, distributed persistent storage, and secure network-edge access control.

## System Architecture & Technical Specifications

* **Orchestration:** K3s (Lightweight Kubernetes)
* **Compute Nodes:**
  * 1x Dell Latitude 7490 (x86_64 / AMD64) - Primary Compute / Control Plane & Storage
  * 1x Raspberry Pi 3 (ARM64) - Edge Compute and Ingress Control
  * 1x Raspberry Pi 4 (ARM64) - Middleweight Compute and Distributed Storage Peer
* **Storage Engine:** Longhorn (Distributed block storage with persistent volume replication)
* **Continuous Delivery:** GitOps driven via Argo CD *(Migration to Flux scheduled)*
* **Ingress & Networking:** Traefik Ingress Controller terminated via edge-routed WireGuard VPN, load balanced by MetalLB
* **Resource Envelope:** 21 GB Total System Memory across node pools (Pi 3: 1 GB; Pi 4: 4 GB; Dell: 16 GB)

## Engineering Constraints & Solutions

* **Heterogeneous Node Scheduling:** Resolved architecture mismatches (ARM64 vs. AMD64) by enforcing multi-arch container image manifests and explicit node affinity and taint/toleration rules.
* **Storage Isolation:** Excluded SD-card-bound nodes (Pi-3) from the Longhorn replica pool to increase storage bandwidth and mitigate storage degradation, offloading distributed storage strictly to wear-levelled media.
* **Resource Optimization:** Managed container density (~24 active workloads) within a tightly constrained RAM ceiling using strict CPU/Memory request and limit allocations.

## Operational Resilience & Post-Mortems

This environment hosts several solutions that I use daily. Below are selected incident post-mortems documenting root-cause analyses and remediation strategies:

### 1. Cascading Resource Exhaustion (OOM)

* **Root Cause:** Application deployed without explicit container memory limits, leading to memory pressure on the node and Linux kernel OOM killer invocation.
* **Remediation:** Enforced resource quotas and defined default `requests` and `limits` across all deployment manifests in the GitOps repository.

### 2. Thermal Throttling & SD Card Disconnects on Pi 3
* **Impact:** The Pi 3 is the ingress node and also served DNS for the home network, so when it degraded, DNS went down for the whole Wi-Fi network.

* **Root Cause:** Heat caused thermal throttling and transient SD card drops. Pods on the node failed their health checks and restarted while the node was still recovering.

* **Remediation:** Improved cooling and increased health check wait periods (initial delay and failure thresholds) on the workloads scheduled to that node, so they could tolerate a slow recovery instead of being restarted in a loop.

### 3. Recovery after Dual-Node Power Loss

* **Root Cause:** Simultaneous dual-node power failure caused container scheduling to fail and resulted in stuck volume attachments in Longhorn.

* **Remediation:** Verified volume integrity, gracefully cleared stale volume attachments and stuck claims, and restarted application deployments without persistent data loss.

## Screenshots
![image ForgeJo](./Screenshots/Forgejo.png)
![image Grafana (Namespace mode)](./Screenshots/Grafana-Namespaces.png)
![image Grafana (Node mode)](./Screenshots/Grafana-Nodes.png)
![image HomePage](./Screenshots/HomePage.png)
![image Immich](./Screenshots/Immich.png)
![image Longhorn](./Screenshots/Longhorn.png)
![image NextCloud](./Screenshots/NextCloud.png)
![image PiHole](./Screenshots/PiHole.png)
![image SearXNG](./Screenshots/SearXNG.png)
![image ArgoCD](./Screenshots/ArgoCD.png)
![image Joplin](./Screenshots/joplin.png)
![image VaultWarden](./Screenshots/Vaultwarden.png)