# Research Report: kubernetes-the-harder-way

## Overview

This repository is a comprehensive, script-based framework for provisioning a production-like Kubernetes cluster entirely on a local machine using QEMU virtual machines. It is inspired by Kelsey Hightower's *Kubernetes the Hard Way* but extends the concept significantly: it targets a local environment (instead of GCP), includes more infrastructure tooling (NFS provisioner, MetalLB, Cilium), and ships with full automation scripts alongside 9 chapters of educational documentation.

---

## Repository Structure

```
kubernetes-the-harder-way/
├── setupall.sh                 # Master orchestrator — single entry point
├── variables.sh                # Software versions & architecture detection
├── helpers.sh                  # Utility functions (id_to_name, sedi, get_upstream_dns)
│
├── VM Lifecycle
│   ├── vmsetup.sh              # Prepare a single VM disk image + cloud-init ISO
│   ├── vmsetupall.sh           # Loop vmsetup.sh for all 7 VMs
│   ├── vmlaunch.sh             # Launch a single VM via QEMU
│   ├── vmlaunchall.sh          # Launch all 7 VMs in a tmux session
│   ├── tapup.sh                # TAP interface helper (Linux bridge attachment)
│   ├── vmsshsetup.sh           # Wait for SSH readiness + known_hosts setup
│   └── vmsshall.sh             # Open SSH sessions to all VMs in tmux windows
│
├── Deployment Scripts
│   ├── deploysetup.sh          # SCP setup scripts to VMs
│   ├── deploybinaries.sh       # Download all binaries and SCP to VMs
│   ├── addaptrepos.sh          # Add Kubernetes & Helm APT repos (Linux)
│   └── addhelmrepos.sh         # Add Helm chart repos (Cilium, CoreDNS, etc.)
│
├── Host & Network Setup
│   ├── setuphost.sh            # Bridge, dnsmasq, iptables NAT, NFS export
│   ├── setuproutes.sh          # Pod CIDR static routes on host
│   └── restartdnsmasq.sh       # Platform-aware dnsmasq restart
│
├── Kubernetes Installation (executed on VMs via SSH)
│   ├── setupcontrol.sh         # etcd + kube-apiserver + controller-manager + scheduler
│   ├── setupnode.sh            # containerd + kubelet + kube-proxy + CNI
│   ├── setupgateway.sh         # IPVS-based API load balancer (ldirectord)
│   ├── setupkubeletaccess.sh   # RBAC ClusterRole for kubelet API access
│   └── setupcluster.sh         # Helm installs: CoreDNS, NFS provisioner, MetalLB, Cilium
│
├── auth/                       # PKI & authentication
│   ├── genauth.sh              # Generate CA + all certificates + kubeconfigs
│   ├── genenckey.sh            # Generate etcd encryption key
│   ├── deployauth.sh           # Distribute certs/keys to VMs
│   ├── setuplocalkubeconfig.sh # Configure local ~/.kube/config
│   ├── ca-config.json          # CA profile (10-year expiry, RSA-2048)
│   ├── ca-csr.json             # CA certificate signing request
│   ├── kubernetes-csr.json     # Multi-SAN API server CSR
│   ├── admin-csr.json          # Admin user CSR
│   ├── kube-scheduler-csr.json
│   ├── kube-controller-manager-csr.json
│   ├── kube-proxy-csr.json
│   ├── service-account-csr.json
│   └── {control,worker}{0-2}-csr.json  # Per-node CSRs
│
├── cloud-init/                 # VM initialization templates
│   ├── user-data.gateway       # Packages: ipvsadm, ldirectord; CA cert trust
│   ├── user-data.control       # Packages: curl; sysctl: arp_announce/ignore; module: br_netfilter
│   ├── user-data.worker        # Packages: nfs-common; module: br_netfilter
│   ├── network-config.gateway  # DHCP + VIP 192.168.42.21/32 on loopback
│   ├── network-config.control  # DHCP + VIP 192.168.42.21/32 on loopback
│   └── network-config.worker   # Empty (DHCP only)
│
├── docs/                       # 10-chapter educational guide
│   ├── 00_Introduction.md
│   ├── 01_Learning_How_to_Run_VMs_with_QEMU.md
│   ├── 02_Preparing_Environment_for_a_VM_Cluster.md
│   ├── 03_Launching_the_VM_Cluster.md
│   ├── 04_Bootstrapping_Kubernetes_Security.md
│   ├── 05_Installing_Kubernetes_Control_Plane.md
│   ├── 06_Spinning_up_Worker_Nodes.md
│   ├── 07_Installing_Essential_Cluster_Services.md
│   ├── 08_Simplifying_Network_Setup_with_Cilium.md
│   └── 09_TLDR_Version_of_the_Guide.md
│
├── .gitignore                  # Ignores generated dirs, images, certs, binaries
├── README.md
└── LICENSE
```

---

## Cluster Architecture

### Virtual Machine Topology

The system creates **7 QEMU VMs** running Ubuntu Plucky (25.04):

| VM ID | Hostname  | Role                 | vCPUs | RAM | IP Address     |
|-------|-----------|----------------------|-------|-----|----------------|
| 0     | gateway   | API Load Balancer    | 2     | 2GB | 192.168.42.10  |
| 1     | control0  | Control Plane (etcd) | 2     | 2GB | 192.168.42.11  |
| 2     | control1  | Control Plane (etcd) | 2     | 2GB | 192.168.42.12  |
| 3     | control2  | Control Plane (etcd) | 2     | 2GB | 192.168.42.13  |
| 4     | worker0   | Worker Node          | 4     | 4GB | 192.168.42.14  |
| 5     | worker1   | Worker Node          | 4     | 4GB | 192.168.42.15  |
| 6     | worker2   | Worker Node          | 4     | 4GB | 192.168.42.16  |

**Total resource consumption**: 20 vCPUs, 20GB RAM.

### Network Topology

```
Internet
   │
   ▼
┌─────────────────────────────────────────────────────────────┐
│ Host Machine (192.168.42.1)                                 │
│   ├── Bridge: kubr0 (Linux) / vmnet-shared (macOS)          │
│   ├── dnsmasq (DHCP + DNS, domain: kubenet)                 │
│   ├── iptables NAT (MASQUERADE for VM internet access)      │
│   ├── NFS server (exports ./nfs-pvs)                        │
│   └── Static routes for pod CIDRs → VM IPs                  │
│                                                             │
│   ┌──────────────────── 192.168.42.0/24 ──────────────────┐ │
│   │                                                        │ │
│   │  gateway (.10)         Virtual IP: 192.168.42.21:6443  │ │
│   │  ├── IPVS (ldirectord)  ──► control0 (.11):6443       │ │
│   │  │                      ──► control1 (.12):6443       │ │
│   │  │                      ──► control2 (.13):6443       │ │
│   │  │                                                     │ │
│   │  control0-2 (.11-.13)                                  │ │
│   │  ├── etcd (3-node cluster, ports 2379/2380)            │ │
│   │  ├── kube-apiserver                                    │ │
│   │  ├── kube-controller-manager                           │ │
│   │  ├── kube-scheduler                                    │ │
│   │  ├── kubelet (tainted NoSchedule)                      │ │
│   │  └── containerd                                        │ │
│   │                                                        │ │
│   │  worker0-2 (.14-.16)                                   │ │
│   │  ├── kubelet                                           │ │
│   │  ├── containerd                                        │ │
│   │  ├── kube-proxy (or Cilium)                            │ │
│   │  └── CNI bridge plugin (or Cilium)                     │ │
│   │                                                        │ │
│   └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

**Key addressing:**
- Host: `192.168.42.1` (also `vmhost` in DNS)
- Kubernetes API VIP: `192.168.42.21` (also `kubernetes.kubenet`)
- DHCP range: `192.168.42.2–192.168.42.20` (static assignments via MAC)
- Pod CIDR: `10.0.0.0/8` — each node gets `10.{vmid}.0.0/16`
- Service CIDR: `10.32.0.0/16`
- Cluster DNS: `10.32.0.10` (CoreDNS)
- MetalLB IP pool: `192.168.42.30–192.168.42.254`

### MAC Address Scheme

Deterministic MAC addresses (`52:52:52:00:00:0{vmid}`) mapped to fixed IPs via dnsmasq DHCP host reservations. This ensures each VM always gets the same IP.

---

## Software Versions (variables.sh)

| Component       | Version  |
|-----------------|----------|
| etcd            | 3.6.2    |
| Kubernetes      | 1.33.2   |
| containerd      | 2.1.3    |
| runc            | 1.3.0    |
| CRI tools       | 1.33.0   |
| CNI plugins     | 1.7.1    |
| CNI spec        | 1.0.0    |
| Ubuntu image    | Plucky (25.04) |

Architecture auto-detection: `arm64`/`aarch64` → `arm64`, `x86_64`/`amd64` → `amd64`.

---

## Complete Provisioning Workflow (setupall.sh)

The master script `setupall.sh` runs the entire provisioning end-to-end. Here is the exact sequence:

### Phase 1: Host Preparation
1. Source `variables.sh` and acquire sudo
2. Install system packages:
   - **macOS**: `brew install qemu wget curl cdrtools dnsmasq tmux cfssl kubernetes-cli helm`
   - **Linux**: `addaptrepos.sh` → `apt install qemu-system-x86 curl genisoimage dnsmasq tmux golang-cfssl nfs-kernel-server kubectl helm`
3. Generate SSH keypair: `ssh-keygen -t ed25519` (non-interactive, empty passphrase)

### Phase 2: Certificate Authority & Auth
4. `auth/genauth.sh` — Generate all TLS certificates using cfssl:
   - CA root certificate
   - Kubernetes API server cert (multi-SAN: all control IPs, VIP, service names)
   - Component certs: scheduler, controller-manager, proxy, service-account
   - Per-node certs: `control{0-2}`, `worker{0-2}` (CN=`system:node:{name}`)
   - Kubeconfigs for: admin, scheduler, controller-manager, proxy, all nodes
5. `auth/genenckey.sh` — Generate 32-byte AES-CBC encryption key for secrets at rest
6. `auth/setuplocalkubeconfig.sh` — Configure `~/.kube/config` for host kubectl

### Phase 3: VM Image Preparation
7. Download Ubuntu cloud image (plucky, ~600MB) — with size-based caching to skip re-downloads
8. `vmsetupall.sh` → `vmsetup.sh` × 7:
   - Create QCOW2 disk (20GB, backed by shared ubuntu-cloud.img)
   - Evaluate cloud-init templates (bash `eval` for variable substitution)
   - Create cloud-init ISO via `mkisofs`

### Phase 4: Host Network & Services
9. `setuphost.sh` (root):
   - **Linux**: Create bridge `kubr0` via netplan, enable IP forwarding, create `kubenet-nat.service` for iptables MASQUERADE
   - Add DNS entries to `/etc/hosts` (all VM hostnames + `kubernetes` VIP)
   - Configure dnsmasq: DHCP range, MAC-to-IP reservations, domain `kubenet`, upstream DNS auto-detection
   - Export `./nfs-pvs` directory via NFS

### Phase 5: Launch VMs
10. `vmlaunchall.sh` — Launch 7 QEMU VMs in a tmux session (`kubenet-qemu`)
11. `vmsshsetup.sh` × 7 — Wait for each VM's SSH port, scan host keys

### Phase 6: Deploy Scripts, Certs & Binaries
12. `deploysetup.sh` — SCP setup scripts to appropriate VMs
13. `auth/deployauth.sh` — SCP certificates & kubeconfigs to VMs
14. `deploybinaries.sh` — Download all binaries to `./bin/`, SCP to VMs (with 3-attempt retry logic)

### Phase 7: Kubernetes Installation (Parallel)
15. `setupcontrol.sh` × 3 (**parallel** via background jobs):
    - Verify pre-deployed etcd archive, install etcd (3-node cluster, TLS mutual auth)
    - Wait for full etcd cluster health (3/3 members started) — synchronization barrier
    - Verify pre-deployed K8s binaries, install kube-apiserver, kube-controller-manager, kube-scheduler
    - All as systemd services
16. `setupgateway.sh` — Configure IPVS load balancer (ldirectord) for API VIP
17. `setupnode.sh` × 6 (**parallel**, 3 control + 3 worker):
    - Install containerd + runc + crictl
    - Install kubelet (with per-node cert, pod CIDR, cgroup driver systemd)
    - If not Cilium: install CNI bridge plugin + kube-proxy
    - Control nodes: tainted with `NoSchedule`

### Phase 8: Post-Installation
18. `setuproutes.sh` — Add pod CIDR routes on host (Linux only, skipped if Cilium)
19. `setupkubeletaccess.sh` — Create RBAC ClusterRole allowing API server to access kubelet endpoints
20. `addhelmrepos.sh` — Register Helm chart repos
21. `setupcluster.sh` — Install cluster services via Helm:
    - (Optional) Cilium CNI with kube-proxy replacement
    - CoreDNS (2 replicas, service IP `10.32.0.10`)
    - NFS subdir external provisioner (default StorageClass)
    - MetalLB (L2 mode, IP pool `192.168.42.30–254`)

---

## Script-by-Script Deep Dive

### variables.sh
Single source of truth for all component versions. Detects CPU architecture at source-time via `uname -m`. Sourced by nearly every other script. Contains no functions — just variable assignments.

### helpers.sh
Three utility functions used across the project:

- **`id_to_name()`**: Maps VM ID (0–6) → hostname. Uses a case statement: 0=gateway, 1–3=control{0-2}, 4–6=worker{0-2}. This is the central abstraction that prevents hostname hardcoding in loops.
- **`sedi()`**: Cross-platform `sed -i`. macOS `sed` requires `-i ''` while GNU sed uses `-i`. Detects OS and wraps appropriately.
- **`get_upstream_dns()`**: Auto-discovers upstream DNS servers. Tries `resolvectl status` first (systemd-resolved), falls back to parsing `/etc/resolv.conf`, and ultimately defaults to `8.8.8.8` + `1.1.1.1` if nothing else works.

### setupcontrol.sh
Runs on each control node (as root, via SSH). Three main sections:

**etcd installation**: Verifies the pre-deployed etcd archive (SCP'd by `deploybinaries.sh`), extracts, installs to `/usr/local/bin`. Creates a systemd unit with full TLS configuration and `TimeoutStartSec=180` (extended from default 90s to allow cluster formation). The 3-node cluster uses `initial-cluster-state new` with hardcoded peer URLs. etcd data stored in `/var/lib/etcd` with `chmod 700`.

**etcd cluster health gate**: After `systemctl start etcd` (which blocks until quorum via `Type=notify`), polls `etcdctl member list` until all 3 members show `started` status. This acts as a synchronization barrier across the 3 parallel `setupcontrol.sh` invocations — no node proceeds to install K8s components until the full etcd cluster is healthy. 120s timeout with diagnostic output on failure.

**Kubernetes control plane**: Verifies pre-deployed kube-apiserver, kube-controller-manager, kube-scheduler binaries (SCP'd by `deploybinaries.sh`), logs each found binary, and errors out listing any missing ones with guidance pointing to `deploybinaries.sh`. Key API server flags:
- Authorization: `Node,RBAC`
- Admission plugins: `NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota`
- Audit logging enabled (30-day retention)
- Service account issuer: `https://192.168.42.21:6443`
- Encryption at rest via `encryption-config.yaml`

Both controller-manager and scheduler use `leaderElect=true` for HA.

**Note**: `setupcontrol.sh` does NOT download any binaries itself. All binaries are pre-deployed by `deploybinaries.sh`. The script verifies their presence and errors out with clear messages if any are missing.

### setupnode.sh
Runs on **all 6 nodes** (control + worker). Detects node type from hostname and computes VM ID to derive pod CIDR (`10.{vmid}.0.0/16`). Key components:

- **containerd**: Configured with systemd cgroup driver, runc v2 runtime, overlay module pre-loaded
- **kubelet**: Webhook authentication (no anonymous), webhook authorization, systemd cgroup driver, resolv.conf at `/run/systemd/resolve/resolv.conf`
- **Control node taint**: `node-roles.kubernetes.io/control-plane=:NoSchedule` — prevents scheduling workloads on masters
- **CNI** (without Cilium): Bridge plugin (`cnio0`) with host-local IPAM, per-node pod subnet
- **kube-proxy** (without Cilium): iptables mode, cluster CIDR `10.0.0.0/12`

**Note**: The kube-proxy config uses `clusterCIDR: "10.0.0.0/12"` while the controller-manager uses `--cluster-cidr=10.0.0.0/8`. This is a minor inconsistency (the /12 is a subset of /8, so it still works, but the ranges don't match semantically).

### setupgateway.sh
Configures the gateway VM as a layer-4 load balancer for the Kubernetes API using Linux IPVS. The virtual IP `192.168.42.21:6443` is already configured on the gateway's loopback via cloud-init. ldirectord monitors the three backends (`control0-2:6443`) using HTTPS health checks to `/healthz`. Scheduling algorithm: weighted round robin.

### setupcluster.sh
Runs on the host machine using kubectl and Helm. Installs:

1. **Cilium** (optional): Replaces kube-proxy entirely (`kubeProxyReplacement=true`), uses host cgroup root, 15-minute wait timeout
2. **CoreDNS**: Pinned to service IP `10.32.0.10`, 2 replicas
3. **NFS provisioner**: Points to host at `192.168.42.1`, absolute path to `nfs-pvs` directory, set as default StorageClass
4. **MetalLB**: Installed with a 3-minute timeout, then configured via kubectl with an `IPAddressPool` (`192.168.42.30–254`) and `L2Advertisement`

### deploybinaries.sh
A two-phase download-then-distribute script. Downloads all binaries once to `./bin/` using wget, then distributes via SCP to appropriate VMs. SCP uses `ConnectTimeout=30` and `BatchMode=yes` for stability, with a 3-attempt retry loop (5-second sleep between attempts). Different binaries go to different node types:

- **Control nodes**: etcd archive, all K8s control plane binaries, kubelet, containerd, crictl, runc (+ optionally CNI/kube-proxy)
- **Worker nodes**: kubelet, containerd, crictl, runc (+ optionally CNI/kube-proxy)

### vmlaunch.sh
QEMU launcher with platform-specific settings:

| Setting    | macOS                                  | Linux                          |
|------------|----------------------------------------|--------------------------------|
| Arch       | aarch64                                | x86_64                         |
| Accel      | hvf (Hypervisor.framework)             | kvm                            |
| Machine    | virt                                   | q35                            |
| NIC        | vmnet-shared                           | tap (with `tapup.sh` script)   |
| EFI        | `/opt/homebrew/share/qemu/edk2-*.fd`   | `/usr/share/qemu/OVMF.fd`     |

All VMs use UEFI boot, host CPU passthrough, and VirtIO for the cloud-init drive.

### vmsetup.sh
Creates two artifacts per VM:
1. **disk.img**: QCOW2 with backing file (`ubuntu-cloud.img`), 20GB max size. Uses copy-on-write so initial size is minimal.
2. **cidata.iso**: Cloud-init configuration ISO created by `mkisofs`. Contains `meta-data`, `user-data`, and `network-config`.

The cloud-init templates use a clever bash eval trick: `eval "cat << EOF\n$(<template_file)\nEOF"` — this allows cloud-init YAML files to contain bash variables like `$(<~/.ssh/id_ed25519.pub)` and `${vmname}` that get substituted at image build time.

### Cloud-Init Details

**user-data.control**: Installs `curl`, enables `br_netfilter` kernel module, configures `arp_announce=2` and `arp_ignore=1` (required for IPVS Direct Server Return — prevents control nodes from answering ARP requests for the VIP).

**user-data.gateway**: Installs `ipvsadm` and `ldirectord`, embeds the Kubernetes CA certificate as a trusted system certificate (required for HTTPS health checks to API server).

**user-data.worker**: Installs `nfs-common` for NFS PersistentVolume support.

**network-config.gateway/control**: Both configure the VIP `192.168.42.21/32` as a static address on the loopback interface — this is a key part of the IPVS DSR (Direct Server Return) setup.

---

## Authentication & PKI Architecture

### Certificate Hierarchy

```
CA (ca.pem / ca-key.pem)
├── kubernetes.pem          API server cert — multi-SAN:
│                           IPs: 10.32.0.1, 192.168.42.{10-16,21}, 127.0.0.1
│                           DNS: kubernetes, kubernetes.default, kubernetes.default.svc,
│                                kubernetes.default.svc.cluster, kubernetes.default.svc.cluster.local,
│                                control0, control1, control2, gateway
├── admin.pem               CN=admin, O=system:masters
├── kube-scheduler.pem      CN=system:kube-scheduler
├── kube-controller-manager.pem  CN=system:kube-controller-manager
├── kube-proxy.pem          CN=system:kube-proxy, O=system:node-proxier
├── service-account.pem     CN=service-accounts (for JWT signing)
├── control{0-2}.pem        CN=system:node:control{0-2}, O=system:nodes
└── worker{0-2}.pem         CN=system:node:worker{0-2}, O=system:nodes
```

**Profile**: All certs use `kubernetes` profile: RSA 2048-bit, 87600h expiry (~10 years), usages: signing, key encipherment, server auth, client auth.

### Kubeconfig Generation

Each kubeconfig is generated with `kubectl config` commands targeting `https://kubernetes:6443` (the VIP hostname). Certificates are embedded (`--embed-certs=true`). The cluster name is `kubenet`.

### Encryption at Rest

`genenckey.sh` generates a 32-byte random key from `/dev/urandom`, base64-encodes it, and creates an `encryption-config.yaml` with provider `aescbc` + `identity` fallback. This encrypts Kubernetes Secrets in etcd.

---

## Networking Deep Dive

### Host-to-VM Connectivity (Linux)

1. **Bridge `kubr0`** created via netplan at `192.168.42.1/24`
2. QEMU TAP interfaces attached to bridge via `tapup.sh` (called automatically by QEMU's `-nic tap,script=...`)
3. **IP forwarding** enabled via sysctl
4. **NAT** via iptables: `MASQUERADE` rule for `192.168.42.0/24` traffic leaving the bridge — gives VMs internet access
5. **dnsmasq** on `kubr0` provides DHCP and DNS to VMs

### Pod Networking (Without Cilium)

Each node runs a CNI bridge plugin (`cnio0`) with host-local IPAM. Pod CIDR per node: `10.{vmid}.0.0/16`. Cross-node pod traffic is routed via static routes on the host machine (`setuproutes.sh`): `10.{vmid}.0.0/16 via 192.168.42.{10+vmid}`.

### Pod Networking (With Cilium)

When `USE_CILIUM` is set, CNI plugins, kube-proxy, and static routes are all skipped. Cilium handles everything: pod networking, service proxying, and network policies.

### API Server Load Balancing

The gateway VM runs an IPVS-based load balancer using ldirectord:
- **VIP**: `192.168.42.21:6443` (configured on loopback of gateway + all control nodes)
- **Backends**: `control{0-2}:6443`
- **Health check**: HTTPS GET `/healthz` expecting 200 OK
- **Algorithm**: Weighted Round Robin (wrr)

The VIP is on the loopback of control nodes too (for DSR), with ARP tuning (`arp_announce=2`, `arp_ignore=1`) to prevent ARP conflicts.

---

## Key Design Patterns

### 1. Idempotent Configuration with Markers
Multiple scripts modify shared config files (`/etc/hosts`, `/etc/dnsmasq.conf`, `/etc/exports`). They use marker comments (`#setuphost_generated_start` / `#setuphost_generated_end`) and `sedi` to delete old sections before re-adding. This makes scripts safe to re-run.

### 2. ID-to-Name Abstraction
The `id_to_name()` function in `helpers.sh` is the single mapping from numeric VM ID (0–6) to hostname. This allows all scripts to iterate with `seq` and derive names, IPs, and resource allocations from the ID alone.

### 3. Parallel Execution with PID Tracking
`setupall.sh` uses bash background jobs for parallel installation:
```bash
pids=()
for i in $(seq 0 2); do
  ssh ubuntu@control$i "sudo ./setupcontrol.sh" &
  pids+=($!)
done
wait ${pids[@]}
```
This is used for both control plane setup (3 parallel) and node setup (6 parallel).

### 4. Bash Eval Templating for Cloud-Init
Cloud-init files are treated as bash templates:
```bash
eval "cat << EOF
$(<"$dir/cloud-init/user-data.$vmtype")
EOF" > "$vmdir/user-data"
```
This allows embedding dynamic content (SSH keys, paths) directly in cloud-init YAML without a separate templating tool.

### 5. SCP Retry Logic
`deploybinaries.sh` wraps all SCP operations in `until` loops with a 3-attempt limit and 5-second backoff. This handles transient SSH failures during VM boot-up.

### 6. "Text file busy" Prevention
Both `setupcontrol.sh` and `setupnode.sh` do `rm -f` on existing binaries before `cp`. This prevents the "Text file busy" error that occurs when overwriting a binary that's currently being executed (relevant for re-runs).

### 7. Pre-Deploy Verification
`setupcontrol.sh` does not download binaries itself. It verifies that `deploybinaries.sh` has already SCP'd the required files (etcd archive, kube-apiserver, kube-controller-manager, kube-scheduler) into the working directory. Each file is checked and logged as found. If any are missing, the script errors out with a clear message listing the missing files and pointing to `deploybinaries.sh` as the prerequisite.

### 8. etcd Cluster Health Gate
After starting etcd on each control node, `setupcontrol.sh` polls `etcdctl member list` until all 3 members report `started`. This synchronization barrier ensures kube-apiserver is never started against a partially-formed etcd cluster. The etcd systemd unit also uses `TimeoutStartSec=180` (extended from the default 90s) to tolerate timing differences between nodes.

### 9. Conditional Cilium Support
The `USE_CILIUM` environment variable acts as a feature toggle throughout the codebase. When set:
- `deploybinaries.sh` skips downloading CNI plugins and kube-proxy
- `setupnode.sh` skips CNI config, kube-proxy installation and service enablement
- `setupall.sh` skips `setuproutes.sh`
- `setupcluster.sh` installs Cilium via Helm before other components

### 10. Cross-Platform OS Detection
Major scripts use `uname -s` (Darwin vs Linux) and `uname -m` (architecture) to branch behavior. This affects: QEMU configuration, package management, network setup, NFS exports, sed behavior, and dnsmasq management.

---

## Hardcoded Values & Assumptions

### Network Constants
| Value | Usage |
|-------|-------|
| `192.168.42.0/24` | VM network subnet |
| `192.168.42.1` | Host IP / NFS server |
| `192.168.42.10` | Gateway VM |
| `192.168.42.11–13` | Control nodes |
| `192.168.42.14–16` | Worker nodes |
| `192.168.42.21` | Kubernetes API VIP |
| `192.168.42.30–254` | MetalLB LB pool |
| `10.0.0.0/8` | Pod CIDR (controller-manager) |
| `10.{vmid}.0.0/16` | Per-node pod CIDR |
| `10.32.0.0/16` | Service CIDR |
| `10.32.0.10` | CoreDNS service IP |
| `52:52:52:00:00:0X` | VM MAC addresses |

### Other Assumptions
- SSH user: `ubuntu` (cloud-init default)
- SSH key type: ed25519 (no passphrase)
- QEMU UEFI boot (OVMF/edk2)
- VM disk size: 20GB (QCOW2, copy-on-write)
- etcd data dir: `/var/lib/etcd` with mode 700
- Domain: `kubenet` (dnsmasq expand-hosts)
- kubelet resolv.conf: `/run/systemd/resolve/resolv.conf` (assumes systemd-resolved)
- Container runtime endpoint: `unix:///var/run/containerd/containerd.sock`

---

## Error Handling Patterns

| Pattern | Where Used |
|---------|------------|
| `set -xe` (exit on error + trace) | Most scripts |
| `set -x` only (trace, no exit on error) | `addhelmrepos.sh` |
| Root check (`$EUID -ne 0`) | `setupcontrol.sh`, `setupnode.sh`, `setuphost.sh` |
| wget with `\|\| { echo ERROR; exit 1; }` | `deploybinaries.sh` |
| Pre-deploy file verification with clear error messages | `setupcontrol.sh` (etcd archive + K8s binaries) |
| Deadline-based health polling with diagnostics on timeout | `setupcontrol.sh` (etcd cluster), `waitforcluster.sh` (API + nodes) |
| SCP retry loop (3 attempts, 5s delay) | `deploybinaries.sh` |
| SSH port wait (`nc -zw 10`) | `vmsshsetup.sh` |
| File existence check | `vmsetup.sh` (SSH public key) |
| Download size caching | `setupall.sh` (Ubuntu image) |

---

## Observations & Potential Issues

### 1. APT Repo Version Mismatch
`addaptrepos.sh` adds the Kubernetes APT repo for `v1.28`, while `variables.sh` specifies `k8s_version=1.33.2`. The APT repo is used to install `kubectl` on the host (which comes from APT), but the actual K8s binaries are downloaded directly from `dl.k8s.io`. This works but means the host's `kubectl` version may differ from the cluster version.

### 2. kube-proxy clusterCIDR Mismatch
`setupnode.sh` configures kube-proxy with `clusterCIDR: "10.0.0.0/12"` while `kube-controller-manager` uses `--cluster-cidr=10.0.0.0/8`. The `/12` is a subset of `/8`, so traffic still routes correctly, but the inconsistency could cause subtle issues with kube-proxy's node-local traffic detection.

### 3. License Discrepancy
The `LICENSE` file contains Apache License 2.0, but `README.md` states the project uses Creative Commons Attribution-NonCommercial-ShareAlike 4.0.

### 4. Upstream DNS Hardcoded Path
In `setuphost.sh`, the upstream DNS loop writes to `/etc/dnsmasq.conf` directly (hardcoded) rather than using the `$dnsmasq_config` variable that was properly set earlier in the same script. This works on Linux but would break the macOS path.

### 5. No `set -e` in addhelmrepos.sh
This script uses `set -x` but not `set -e`, meaning Helm repo add failures are logged but don't stop execution. This is probably intentional (idempotent re-runs) but means silent failures are possible.

### 6. Single Points of Failure
- The gateway VM is a single load balancer (no HA for the LB itself)
- NFS storage is hosted on the bare metal host (no replication)
- These are acceptable for an educational setup

### ~~7. setupcontrol.sh redundantly downloaded pre-deployed binaries~~ (RESOLVED)
Previously, `setupcontrol.sh` re-downloaded etcd and K8s binaries via `wget_retry` even though `deploybinaries.sh` had already SCP'd them to each control node. This added unnecessary network requests (HEAD timestamp checks) that could fail on flaky networks. **Fixed**: replaced wget calls with pre-deploy file verification that logs found/missing status and errors out clearly if `deploybinaries.sh` wasn't run first.

### ~~8. etcd bootstrap race condition in parallel setupcontrol.sh~~ (RESOLVED)
Previously, all 3 `setupcontrol.sh` invocations ran fully in parallel with no synchronization between etcd startup and K8s component installation. If nodes reached `systemctl start etcd` at different times, the default 90s `TimeoutStartSec` could expire before quorum formed. After quorum (2/3), kube-apiserver started immediately without waiting for the third etcd member. **Fixed**: added `TimeoutStartSec=180` to etcd unit, plus an etcd cluster health gate that waits for all 3 members to be `started` before proceeding.

---

## Documentation Quality

The `docs/` directory contains 10 well-structured chapters covering:

1. **Conceptual foundations**: QEMU/KVM/HVF, virtualization, cloud-init, DHCP/DNS
2. **Step-by-step instructions**: Each chapter walks through commands with explanations
3. **Architecture diagrams**: Network topology, component relationships
4. **Cross-references**: Chapters link to each other and to the TLDR version
5. **Platform awareness**: Each page has macOS/Linux toggle links

The docs use `doctoc` for auto-generated tables of contents and include both educational prose and concrete commands. Chapter 09 (TLDR) provides a condensed reference for experienced users.

---

## Summary

This is a well-engineered educational project that provisions a complete, production-like Kubernetes cluster (3 control + 3 worker + 1 gateway) on a single machine using QEMU VMs. It demonstrates every layer of the stack from bare metal networking (bridges, TAP interfaces, IPVS, iptables NAT) through PKI certificate management (cfssl) to Kubernetes component installation (etcd, API server, kubelet, containerd) and cluster services (CoreDNS, MetalLB, NFS provisioner, optional Cilium). The codebase is well-organized around a single orchestrator script (`setupall.sh`) that coordinates ~20 focused scripts, uses parallel execution for performance, and includes retry logic for reliability. The optional Cilium support provides a clean example of how a CNI plugin replaces multiple lower-level components.
