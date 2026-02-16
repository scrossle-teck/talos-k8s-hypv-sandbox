# Talos K8s Hyper-V Sandbox

A minimal two-node Kubernetes cluster running [Talos Linux](https://www.talos.dev/) on Hyper-V, with a production-style platform stack: Cilium CNI, Traefik ingress, MetalLB load balancer, and Prometheus/Grafana monitoring.

Built for local development and learning on Windows (including ARM64/Windows-on-ARM).

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Windows Host (Hyper-V)                                 │
│                                                         │
│  ┌─────────────────────┐  ┌─────────────────────────┐   │
│  │ talos-hypv-cp-01    │  │ talos-hypv-worker-01    │   │
│  │ Control Plane       │  │ Worker                  │   │
│  │ 2 vCPU / 4GB RAM    │  │ 2 vCPU / 4GB RAM        │   │
│  │ 20GB VHDX           │  │ 20GB VHDX               │   │
│  │ Talos v1.12.4       │  │ Talos v1.12.4           │   │
│  └─────────────────────┘  └─────────────────────────┘   │
│         Default Switch (NAT, DHCP)                      │
└─────────────────────────────────────────────────────────┘
```

### Platform Stack

| Component | Purpose | Version |
|-----------|---------|---------|
| **Cilium** | CNI + kube-proxy replacement (eBPF) | Latest via Helm |
| **Hubble** | Network observability (part of Cilium) | Bundled with Cilium |
| **MetalLB** | LoadBalancer IP allocation (L2 mode) | Latest via Helm |
| **Traefik** | Ingress controller | Latest via Helm |
| **Prometheus** | Metrics collection (7d retention) | kube-prometheus-stack |
| **Grafana** | Dashboards and visualization | kube-prometheus-stack |

## Prerequisites

- Windows 10/11 with **Hyper-V** enabled
- **talosctl** in PATH ([install guide](https://www.talos.dev/v1.12/introduction/getting-started/))
- **kubectl** in PATH
- **Helm** in PATH (`winget install Helm.Helm`)

## Quick Start

### 1. Create the cluster

```powershell
# Run as Administrator
.\create-cluster.ps1
```

This downloads the Talos ISO, creates two VMs, applies configs, bootstraps the cluster, and saves credentials to `_out/`.

### 2. Deploy the platform stack

Run each script in order from an elevated PowerShell prompt:

```powershell
# Replace Flannel with Cilium CNI + Hubble
.\deployments\cilium\deploy.ps1

# Install MetalLB for LoadBalancer support
.\deployments\metallb\deploy.ps1

# Install Traefik ingress controller
.\deployments\traefik\deploy.ps1

# Set up hostname-based routing for dashboards
.\deployments\ingress\deploy.ps1

# Install Prometheus + Grafana monitoring
.\deployments\monitoring\deploy.ps1
```

### 3. Access dashboards

After running the ingress deploy script (which updates your hosts file):

| URL | Service | Credentials |
|-----|---------|-------------|
| `http://grafana.talos.local` | Grafana | admin / admin |
| `http://prometheus.talos.local` | Prometheus | — |
| `http://hubble.talos.local` | Hubble UI | — |
| `http://traefik.talos.local/dashboard/` | Traefik | — |

> **Grafana login:** The default username and password are both `admin`. You'll be prompted to change the password on first login — you can skip this for a sandbox.

## Scaling the Cluster

### Add a Node

Add control plane or worker nodes dynamically:

```powershell
# Add a worker node (auto-detects next number: worker-02, worker-03, etc.)
.\scale-add-node.ps1 -NodeType worker

# Add a control plane node for HA
.\scale-add-node.ps1 -NodeType controlplane
```

The script will:

- Auto-detect the next available node number
- Create the Hyper-V VM with matching specs
- Apply the appropriate Talos machine config
- Re-detect IP after VM reboot (DHCP may reassign)
- Wait for the node to join and become Ready
- Verify etcd membership (for control-plane nodes)

**Note:** Talos auto-generates hostnames (e.g., `talos-c6h-dm3`), not VM names. Use `kubectl get nodes` to see actual node names.

### Remove a Node

Remove a node gracefully:

```powershell
# Remove by Kubernetes node name (preferred)
.\scale-remove-node.ps1 -NodeName talos-xyz-abc

# Remove by VM name (also works)
.\scale-remove-node.ps1 -NodeName talos-hypv-worker-02

# Force removal without prompts
.\scale-remove-node.ps1 -NodeName talos-hypv-cp-03 -Force
```

The script will:

- Resolve between VM name and Kubernetes node name
- Drain workloads (for worker nodes only)
- **Remove from etcd cluster (for control-plane nodes)**
- Delete the node from Kubernetes
- Shut down and remove the VM
- Delete the VHDX disk

**Warnings:**

- Removing control-plane nodes can impact cluster availability. Maintain an odd number (1, 3, 5) for quorum.
- The script prevents removing the last control-plane node (cluster would be destroyed).
- etcd quorum: 1 node = no tolerance, 3 nodes = 1 failure tolerated, 5 nodes = 2 failures tolerated.

## Tear Down

```powershell
# Run as Administrator
.\destroy-cluster.ps1
```

This stops and deletes both VMs, removes their VHDX disks, and cleans up `_out/`.

You may also want to remove the `# talos-sandbox-ingress` entries from your hosts file (`C:\Windows\System32\drivers\etc\hosts`).

## Project Structure

```
├── create-cluster.ps1              # Provision VMs and bootstrap Talos
├── destroy-cluster.ps1             # Tear down VMs and clean up
├── scale-add-node.ps1              # Add control plane or worker nodes
├── scale-remove-node.ps1           # Remove nodes gracefully
├── _out/                           # Generated configs (gitignored)
│   ├── controlplane.yaml
│   ├── worker.yaml
│   ├── talosconfig
│   └── kubeconfig
├── iso/                            # Cached Talos ISO (gitignored)
└── deployments/
    ├── cilium/
    │   ├── talos-patch.yaml        # Disable Flannel + kube-proxy
    │   ├── cilium-values.yaml      # Helm values (Talos-specific)
    │   └── deploy.ps1
    ├── metallb/
    │   ├── metallb-pool.yaml       # L2 advertisement + IP pool template
    │   └── deploy.ps1              # Auto-detects subnet for IP pool
    ├── traefik/
    │   ├── traefik-values.yaml     # Helm values (LoadBalancer service)
    │   └── deploy.ps1
    ├── ingress/
    │   ├── ingressroutes.yaml      # Traefik routes for all dashboards
    │   └── deploy.ps1              # Applies routes + updates hosts file
    └── monitoring/
        ├── kube-prometheus-values.yaml  # Helm values (laptop-sized)
        └── deploy.ps1
```

## Troubleshooting

### Orphaned VHDX Files

**Symptom:** Node creation fails with "The file exists" error for a VHDX file.

**Cause:** Previous VM was deleted without removing its disk, or a partial failure left orphaned files.

**Solution:**

```powershell
# Check for orphaned VHDX files
Get-ChildItem 'C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\talos-hypv-*.vhdx'

# Remove orphaned file
Remove-Item 'C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\talos-hypv-<name>.vhdx' -Force

# Retry the operation
.\scale-add-node.ps1 -NodeType worker
```

### IP Address Not Detected

**Symptom:** Script times out waiting for VM IP address.

**Possible causes:**

1. Hyper-V Default Switch not configured
2. VM network adapter not connected
3. Slow VM boot (ARM64 hardware)

**Solution:**

```powershell
# Check Default Switch exists
Get-VMSwitch

# Check VM network adapter
Get-VMNetworkAdapter -VMName talos-hypv-cp-01

# Check ARP table manually
Get-NetNeighbor -LinkLayerAddress <MAC> | Where-Object AddressFamily -eq IPv4
```

### etcd Member Not Joining

**Symptom:** Control-plane node joins Kubernetes but not etcd cluster.

**Diagnosis:**

```powershell
# Check etcd members
talosctl --talosconfig _out\talosconfig -n <cp-ip> etcd members

# Check if all control-plane nodes are listed
kubectl get nodes -l node-role.kubernetes.io/control-plane
```

**Solution:** Talos should auto-join etcd. If it fails, the best approach is to remove and re-add the node.

### Cluster Health Check Timeout (ARM64)

**Symptom:** Bootstrap times out on ARM64 Windows hardware.

**Cause:** ARM64 processors take longer to bootstrap etcd and Kubernetes components.

**Expected:** Bootstrap can take 9-11 minutes on ARM64 vs. 3-5 minutes on x86_64. This is normal.

## Notes

### Hyper-V Default Switch

The Default Switch uses NAT with DHCP, and the subnet changes on host reboot. After a reboot:

1. Node IPs will change (DHCP reassignment)
2. MetalLB pool range will be invalid
3. Hosts file entries will point to old IPs

To recover, re-run `deployments/metallb/deploy.ps1` and `deployments/ingress/deploy.ps1`.

### Cilium on Talos

Cilium requires Talos-specific Helm values because Talos is immutable:

- `ipam.mode=kubernetes` — use Kubernetes IPAM (Talos best practice)
- `cgroup.autoMount.enabled=false` — Talos pre-mounts cgroupv2
- `kubeProxyReplacement=true` — Cilium replaces kube-proxy via eBPF
- `k8sServiceHost=localhost:7445` — KubePrism local API proxy
- SYS_MODULE capability dropped — Talos doesn't allow kernel module loading from pods

### Monitoring on Talos

Several kube-prometheus-stack monitors are disabled because Talos doesn't expose those components:

- `kubeProxy` — replaced by Cilium
- `kubeScheduler`, `kubeControllerManager`, `kubeEtcd` — not accessible on Talos

The `monitoring` namespace requires the `pod-security.kubernetes.io/enforce=privileged` label for node-exporter to function.

## Production Readiness

This cluster management system has been validated through autonomous lifecycle testing:

✅ **Tested Operations:**

- Full cluster creation (2-node base cluster)
- Dynamic scaling (add/remove control-plane and worker nodes)
- etcd member management (add verification, removal cleanup)
- Last-node protection (prevents destroying cluster)
- Complete cluster destruction with cleanup

✅ **Robustness Features:**

- IP re-detection after VM reboot (DHCP-safe)
- Dual-name node resolution (VM name or Kubernetes name)
- Orphaned resource cleanup
- Graceful error handling and recovery
- MAC-based IP discovery (works without Hyper-V integration services)

✅ **Safety Guards:**

- Confirmation prompts for destructive operations (bypass with `-Force`)
- Last control-plane node protection
- Worker drain before removal
- Proper etcd quorum management

**Validation Results:** ~15 minutes for full lifecycle test (create → scale up → scale down → destroy) on ARM64 Windows, zero manual intervention required.
