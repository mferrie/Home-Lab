# Multi-Architecture k3s Edge Cluster & GitOps Infrastructure

## Project Overview
A declarative, multi-architecture Kubernetes (k3s) cluster managing 16 stateful and stateless services across a hybrid node pool (ARM64 edge devices and x86_64 compute). Designed for high resource density within a 25GB RAM footprint, leveraging automated GitOps pipelines, distributed persistent storage, and secure network-edge access control.

## Repository Structure

```text
├── Incident Reports/       # Detailed root-cause analyses and recovery runbooks
├── Screenshots/            # Cluster telemetry, Argo CD topology, and service UI captures
└── k3s/                    # Declarative Kubernetes manifests & Helm configurations
    ├── cert-manager/       # Automated TLS certificate issuance and renewal
    ├── forgejo/            # Self-hosted Git service backing GitOps workflows
    ├── homepage/           # Unified cluster dashboard and service status aggregation
    ├── immich/             # Self-hosted photo/video management and ML pipelines
    ├── joplin/             # Note-taking sync server
    ├── lgtm/               # Full observability stack tuned for constrained RAM
    │   ├── grafana/        # Cluster, node, and namespace telemetry dashboards
    │   ├── loki/           # Lightweight log aggregation
    │   ├── prometheus/     # Metrics scraping and retention policies
    │   └── tempo/          # Distributed tracing backend
    ├── longhorn/           # Distributed block storage classes and node disk scheduling
    ├── mealie/             # Recipe and meal-planning application
    ├── metallb/            # Bare-metal Layer-2 load balancer IP pools
    ├── nextcloud/          # Self-hosted cloud storage and collaboration suite
    ├── pihole-unbound/     # Recursive DNS resolution and network-wide ad blocking
    ├── searxng/            # Privacy-respecting metasearch engine
    ├── vaultwarden/        # Bitwarden-compatible credential vault
    └── vikunja/            # Task and project management service
```

## Cluster Architecture

```mermaid
flowchart TB
    subgraph External["Network Edge & Remote Access"]
        Client["Client Devices"] -->|Encrypted Tunnel| WG["WireGuard VPN"]
        WG -->|LAN / VPN Traffic| MLB["MetalLB (L2 Load Balancer)"]
    end

    subgraph Cluster["Hybrid Multi-Architecture k3s Cluster (21 GB Total RAM)"]
        subgraph Pi3["Node 1: Raspberry Pi 3 (ARM64 | 1 GB RAM | Edge & Ingress)"]
            Traefik["Traefik Ingress Controller<br/>+ cert-manager (TLS)"]
            DNS["Pi-hole + Unbound<br/>(Recursive DNS)"]
        end

        subgraph Dell["Node 2: Dell Latitude 7490 (x86_64 | 16 GB RAM | Primary Compute & Control Plane)"]
            Control["k3s Control Plane & Argo CD"]
            Forgejo["Forgejo (GitOps Source)"]
            AppsMain["Heavy Workloads<br/>(Immich, Nextcloud, Vaultwarden, etc.)"]
            LGTM["LGTM Observability Stack<br/>(Loki, Grafana, Tempo, Prometheus)"]
            LH1["Longhorn Primary Storage<br/>(Wear-Levelled SSD)"]
        end

        subgraph Pi4["Node 3: Raspberry Pi 4 (ARM64 | 4 GB RAM | Compute & Storage Peer)"]
            AppsEdge["Lightweight Workloads<br/>(Homepage, SearXNG, Mealie, Vikunja)"]
            LH2["Longhorn Replica Peer<br/>(Wear-Levelled Storage)"]
        end
    end

    MLB --> Traefik
    Client -.->|DNS Queries| DNS
    Traefik -->|HTTP/S Routing| AppsMain
    Traefik -->|HTTP/S Routing| AppsEdge
    Traefik -->|Dashboard Access| LGTM

    Forgejo -->|Manifests & Helm Values| Control
    Control -->|Declarative Sync| Pi3
    Control -->|Declarative Sync| Dell
    Control -->|Declarative Sync| Pi4

    AppsMain -->|PVC Read/Write| LH1
    AppsEdge -->|PVC Read/Write| LH2
    LH1 <-->|"Block Replication<br/>(Pi 3 Excluded)"| LH2

    LGTM -.->|Metrics, Logs & Traces| Pi3
    LGTM -.->|Metrics, Logs & Traces| Dell
    LGTM -.->|Metrics, Logs & Traces| Pi4
```

## Engineering Constraints & Solutions

* **Heterogeneous Node Scheduling:** Resolved architecture mismatches (ARM64 vs. AMD64) by enforcing multi-arch container image manifests and explicit node affinity and taint/toleration rules.
* **Storage Isolation:** Excluded SD-card-bound nodes (`pi-3`) from the Longhorn replica pool to increase storage bandwidth and mitigate storage degradation, offloading distributed storage strictly to wear-levelled media.
* **Resource Optimization:** Managed container density (14 active workloads) within a tightly constrained RAM ceiling using strict CPU/Memory request and limit allocations.

## Operational Resilience & Post-Mortems

This environment hosts several solutions that I use daily. Below are selected incident post-mortems documenting root-cause analyses and remediation strategies:

### 1. Cascading Resource Exhaustion (OOM)

* **Root Cause:** Application deployed without explicit container memory limits, leading to memory pressure on the node and Linux kernel OOM killer invocation.
* **Remediation:** Enforced resource quotas and defined default `requests` and `limits` across all deployment manifests in the GitOps repository.

### 2. Thermal Throttling & SD Card Disconnects on Pi 3
* **Impact:** The Pi 3 is the ingress node and also serves DNS for the home network, so when it degraded, DNS went down for the whole Wi-Fi network.

* **Root Cause:** Heat caused thermal throttling and transient SD card drops. Pods on the node failed their health checks and restarted while the node was still recovering.

* **Remediation:** Improved cooling and increased health check wait periods (initial delay and failure thresholds) on the workloads scheduled to that node, so they could tolerate a slow recovery instead of being restarted in a loop.

### 3. Recovery after Dual-Node Power Loss

* **Root Cause:** Simultaneous dual-node power failure caused container scheduling to fail and resulted in stuck volume attachments in Longhorn.

* **Remediation:** Verified volume integrity, gracefully cleared stale volume attachments and stuck claims, and restarted application deployments without persistent data loss.

## Screenshots & Telemetry

### Core Infrastructure & Observability
<details>
<summary><strong>Click to view application screenshots (4 images)</strong></summary>
<br>

**Grafana — Node Resource Utilization (21 GB Envelope)**
![Grafana (Node mode)](./Screenshots/Grafana_Usage_Per_Node.png)

**Grafana — Namespace Workload Footprint**
![Grafana (Namespace mode)](./Screenshots/Grafana_Usage_Per_Namespace.png)

**Argo CD — Declarative GitOps Application Topology**
![ArgoCD](./Screenshots/ArgoCD.png)

**Longhorn — Distributed Storage & Replica Scheduling**
![Longhorn](./Screenshots/Longhorn.png)

</details>

### Utility Services
<details>
<summary><strong>Click to view hosted application & edge service screenshots (8 services)</strong></summary>
<br>

**Homepage - Unified Cluster Dashboard**
![HomePage](./Screenshots/HomePage.png)

**Forgejo - Self-Hosted GitOps Source Repository**
![ForgeJo](./Screenshots/Forgejo.png)

**Pi-hole + Unbound - Recursive DNS & Query Filtering**
![PiHole](./Screenshots/PiHole.png)

**Immich - Self-Hosted Media & ML Management**
![Immich](./Screenshots/Immich.png)

**Nextcloud - Cloud Storage & Collaboration**
![NextCloud](./Screenshots/NextCloud.png)

**Vaultwarden - Credential Management**
![VaultWarden](./Screenshots/Vaultwarden.png)

**SearXNG - Privacy-Respecting Metasearch**
![SearXNG](./Screenshots/SearXNG.png)

**Joplin - Encrypted Note Synchronization**
![Joplin](./Screenshots/joplin.png)

</details>
