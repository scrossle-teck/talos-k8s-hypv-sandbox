# Talos Kubernetes Hyper-V Sandbox - Claude Instructions

## Project Overview

This is a **production-ready** Talos Kubernetes cluster management system for Hyper-V on Windows (including ARM64 Windows-on-ARM). The project provides automated cluster lifecycle management with proper etcd member handling and safety guards.

**Architecture:**
- Minimal 2-node cluster: 1 control-plane + 1 worker
- Dynamic scaling: Add/remove control-plane and worker nodes
- Hyper-V Default Switch networking (DHCP 172.x.x.x range)
- Talos Linux v1.12.4+ (immutable Kubernetes OS)

## Scripts and Their Roles

### Core Cluster Management

1. **create-cluster.ps1** - Creates initial 2-node cluster
   - Handles DHCP IP changes after reboot (critical!)
   - Includes 30s bootstrap stabilization delay
   - Robust IP detection with MAC validation

2. **destroy-cluster.ps1** - Destroys entire cluster
   - Dynamically discovers ALL cluster VMs (`talos-hypv-*`)
   - Removes VMs, VHDXs, and config files
   - Safe to run on empty cluster (exits gracefully)

3. **scale-add-node.ps1** - Adds control-plane or worker nodes
   - Auto-detects next available node number
   - Re-detects IP after reboot (DHCP may reassign)
   - Verifies etcd membership for control-plane nodes
   - Node naming: Talos auto-generates hostnames (e.g., `talos-c6h-dm3`)

4. **scale-remove-node.ps1** - Removes nodes with proper cleanup
   - Dual-name support: accepts VM name OR k8s node name
   - Drains workers (not control-plane - they have taints)
   - **etcd member management:** Removes CP nodes from etcd cluster
   - **Last-node protection:** Prevents removing last control-plane

## Critical Learnings

### 1. IP Address Management (CRITICAL)

**Problem:** Hyper-V Default Switch can reassign IPs during VM reboots.

**When it happens:**
- After applying Talos config (ISO boot → disk boot transition)
- After ejecting ISO and restarting VM

**Solution Pattern (used in create-cluster.ps1 and scale-add-node.ps1):**
```powershell
# Detect IP before config apply
$nodeIp = Wait-ForVmIp -VMName $vmName

# Apply config, eject ISO, reboot...

# RE-DETECT IP after reboot (CRITICAL!)
$nodeIp = Wait-ForVmIp -VMName $vmName

# Now use the NEW IP for Talos API calls
```

**Commit references:**
- create-cluster.ps1: `062a33c` (Fix IP detection after VM reboot)
- scale-add-node.ps1: `cdd4c05` (Fix IP re-detection after reboot)

### 2. etcd Member Management (CRITICAL FOR HA)

**Problem:** Control-plane nodes must be properly added/removed from etcd cluster.

**etcd Quorum Rules:**
- 1 node: No fault tolerance (can't lose any)
- 2 nodes: No fault tolerance (requires 2/2 = 100%)
- 3 nodes: 1 failure tolerated (requires 2/3 = majority)
- 5 nodes: 2 failures tolerated (requires 3/5 = majority)

**Removal Workflow (scale-remove-node.ps1):**
1. Find remaining control-plane node
2. Query etcd members: `talosctl -n <cp-ip> etcd members`
3. Parse member ID by hostname
4. Remove: `talosctl -n <cp-ip> etcd remove-member <id>`
5. Delete from Kubernetes
6. Remove VM/VHDX

**Commit reference:** `f66456b` (Add etcd member management for control-plane removal)

**Addition Workflow (scale-add-node.ps1):**
- Talos *should* auto-join etcd when applying control-plane config
- Script verifies membership after boot
- Warns if node didn't join (check manually)

**Commit reference:** `4f91b23` (Add etcd membership verification)

### 3. Talos Auto-Generated Hostnames

**Problem:** Talos generates random hostnames, not VM names.

**Examples:**
- VM name: `talos-hypv-worker-02`
- Talos hostname: `talos-c6h-dm3`

**Impact:**
- Cannot use VM names in `kubectl` commands
- Must resolve via IP address or use k8s node names

**Solution (scale-remove-node.ps1):**
- Dual-name support: accepts VM name OR k8s node name
- Maps between them using IP addresses via ARP table

**Commit reference:** `a04b7e5` (Fix node verification - removed wrong kubectl wait)

### 4. Robust IP Detection Pattern

**All scripts use this pattern (backported across all scripts):**

```powershell
function Wait-ForVmIp {
    # 1. Wait for valid MAC address (not 000000000000)
    # 2. Convert MAC to ARP-compatible format (XX-XX-XX-XX-XX-XX)
    # 3. Query ARP table for matching MAC
    # 4. Filter for Default Switch subnet (172.x.x.x)
    # 5. Exclude gateway IPs (*.*.*.1)
    # 6. Exclude link-local (169.254.x.x)
    # 7. Return first match only
}
```

**Why this is necessary:**
- Talos omits Hyper-V integration services (security/minimalism)
- `Get-VMNetworkAdapter.IPAddresses` is always empty
- ARP table lookup is the only reliable method

**Defensive filters prevent:**
- Using gateway IPs (.1 addresses)
- Using physical network IPs (wrong subnet)
- Using VPN adapter IPs
- Using stale ARP entries

### 5. PowerShell stderr Handling

**Problem:** kubectl warnings to stderr cause script failures.

**Example:**
```powershell
kubectl drain node --ignore-daemonsets 2>&1
# Warning: ignoring DaemonSet-managed Pods...
# ^ Goes to stderr, captured by 2>&1, treated as error!
```

**Solution:** Don't redirect stderr unless necessary. Let warnings pass through.

**Commit reference:** `aa6ea8e` (Fix kubectl drain stderr handling)

### 6. Bootstrap Timing Issues

**Problem:** `talosctl bootstrap` returns before API server is ready.

**Solution:** Add 30s delay after bootstrap before running health check.

```powershell
talosctl bootstrap
Write-Warn 'Waiting for API server to stabilize...'
Start-Sleep -Seconds 30  # Critical delay!
talosctl health --wait-timeout 600s
```

**Commit reference:** `53c7a7a` (Add stabilization delay after bootstrap)

## Testing Procedures

### Full Lifecycle Test (Autonomous Run)

```powershell
# 1. Create base cluster
.\create-cluster.ps1

# Verify:
kubectl --kubeconfig _out\kubeconfig get nodes
# Expected: 2 nodes (1 CP, 1 worker), both Ready

# 2. Add second control plane (HA setup)
.\scale-add-node.ps1 -NodeType controlplane

# Verify:
kubectl --kubeconfig _out\kubeconfig get nodes
# Expected: 3 nodes (2 CP, 1 worker)

talosctl --talosconfig _out\talosconfig -n <cp-ip> etcd members
# Expected: 2 etcd members listed

# 3. Add second worker
.\scale-add-node.ps1 -NodeType worker

# Verify:
kubectl --kubeconfig _out\kubeconfig get nodes
# Expected: 4 nodes (2 CP, 2 workers)

# 4. Remove second worker
kubectl --kubeconfig _out\kubeconfig get nodes
# Note the k8s node name (e.g., talos-xyz-abc)

.\scale-remove-node.ps1 -NodeName <k8s-node-name>
# Type 'yes' at confirmation prompt

# Verify:
kubectl --kubeconfig _out\kubeconfig get nodes
# Expected: 3 nodes (2 CP, 1 worker)

# 5. Remove second control plane
kubectl --kubeconfig _out\kubeconfig get nodes -l node-role.kubernetes.io/control-plane
# Note the k8s node name of the second CP

.\scale-remove-node.ps1 -NodeName <k8s-cp-node-name>
# Type 'yes' at confirmation

# Verify etcd member removed:
talosctl --talosconfig _out\talosconfig -n <remaining-cp-ip> etcd members
# Expected: 1 etcd member

# 6. Test last-node protection
.\scale-remove-node.ps1 -NodeName <last-cp-node> -Force
# Expected: Error "Cannot remove the last control plane node!"

# 7. Destroy cluster
.\destroy-cluster.ps1

# Verify:
Get-VM -Name talos-hypv-*
# Expected: No VMs found
```

### Expected Timings (ARM64 Windows)

- **Cluster creation:** 10-15 minutes
- **Node addition:** 5-7 minutes
- **Node removal:** 2-3 minutes
- **Cluster destruction:** 1-2 minutes

**Note:** ARM64 is slower than x86_64. Bootstrap can take 9-11 minutes on ARM64 hardware.

## Known Issues and Workarounds

### Issue 1: etcd Auto-Join Failure (Control-Plane Nodes)

**Symptom:** Second control-plane node joins Kubernetes but not etcd.

**Diagnosis:**
```powershell
kubectl get nodes
# Shows 2 control-plane nodes

talosctl -n <cp-ip> etcd members
# Shows only 1 member
```

**Root Cause:** Unknown - Talos should auto-join etcd when applying control-plane config.

**Current State:**
- scale-add-node.ps1 now warns if node doesn't appear in etcd
- Manual intervention required if auto-join fails

**Workaround (if needed):**
- Manual etcd member addition is complex
- Best practice: Destroy and recreate cluster
- For production: Start with 3+ control-plane nodes

### Issue 2: Stale ARP Entries

**Symptom:** Wrong IP detected after VM operations.

**Mitigation:**
- Subnet filtering (172.x only)
- Gateway exclusion (.1 addresses)
- First-match-only selection
- These are now standard in all scripts

## File Structure

```
talos-k8s-hypv-sandbox/
├── create-cluster.ps1          # Creates base cluster
├── destroy-cluster.ps1         # Destroys all cluster VMs
├── scale-add-node.ps1          # Adds nodes (CP or worker)
├── scale-remove-node.ps1       # Removes nodes (CP or worker)
├── iso/                        # Talos ISO downloads
│   └── metal-arm64.iso         # Auto-detected architecture
├── _out/                       # Generated configs (gitignored)
│   ├── talosconfig             # Talos cluster auth
│   ├── kubeconfig              # Kubernetes auth
│   ├── controlplane.yaml       # CP machine config
│   └── worker.yaml             # Worker machine config
├── deployments/                # Optional platform services
│   ├── cilium/
│   ├── traefik/
│   ├── metallb/
│   └── monitoring/
└── README.md                   # User documentation
```

## Architecture Notes

### Hyper-V Default Switch Behavior

- **NAT with DHCP:** VMs get 172.x.x.x addresses
- **No static IPs:** DHCP can reassign on reboot
- **Gateway:** Always *.*.*.1 (exclude in IP detection)
- **Subnet changes:** Can change between host reboots (rare)

### Talos Design Choices

**Why no Hyper-V integration services?**
- Security: Minimal attack surface
- Immutability: No unnecessary packages
- Consistency: Same image for all platforms

**Impact on scripts:**
- Can't use `Get-VMNetworkAdapter.IPAddresses` (always empty)
- Must use ARP table lookups via MAC address
- More complex IP detection logic required

## Commit History (This Session)

1. `77dc21a` - Fix control-plane detection bug (label check)
2. `f22499f` - Add robustness to scale-remove-node
3. `062a33c` - Fix IP detection after VM reboot
4. `53c7a7a` - Add bootstrap stabilization delay
5. `f66456b` - **Add etcd member management** (production-critical)
6. `aa6ea8e` - Fix kubectl drain stderr handling
7. `cdd4c05` - Fix IP re-detection in scale-add-node
8. `a04b7e5` - Fix node verification (wrong node name)
9. `4f91b23` - Add etcd membership verification
10. `c0b25e3` - Make destroy-cluster dynamic

## Production Readiness Checklist

✅ **Robustness**
- IP re-detection after reboot
- MAC address validation
- Subnet filtering
- Gateway exclusion
- Stale ARP entry handling

✅ **Safety**
- Last control-plane protection
- Graceful drain for workers
- etcd member management
- Confirmation prompts (bypass with -Force)

✅ **Error Handling**
- Proper exit codes
- Clear error messages
- Graceful degradation
- Partial failure recovery

✅ **Consistency**
- All scripts use same IP detection pattern
- Uniform error handling approach
- Consistent message formatting
- Predictable behavior

✅ **Documentation**
- Inline comments explain "why"
- PowerShell help blocks (.SYNOPSIS, .DESCRIPTION)
- Clear parameter validation
- Usage examples

## Future Enhancements (Optional)

**Low Priority (nice-to-have):**
- Hostname configuration: Set Talos hostname to match VM name
- Parallel node operations: Add multiple nodes simultaneously
- Health check improvements: More granular status reporting
- Config templating: Customize node resources per type
- Cluster backup: etcd snapshot automation
- Upgrade automation: Rolling Talos/Kubernetes upgrades

**Not Recommended:**
- Static IP assignment: Breaks Default Switch simplicity
- Custom network switch: Requires manual configuration
- Mixed architectures: Talos ISOs are architecture-specific

## Quick Reference

### Get Cluster Info
```powershell
# Nodes
kubectl --kubeconfig _out\kubeconfig get nodes -o wide

# etcd Members
talosctl --talosconfig _out\talosconfig -n <cp-ip> etcd members

# etcd Health
talosctl --talosconfig _out\talosconfig -n <cp-ip> etcd status

# All VMs
Get-VM -Name talos-hypv-*

# Cluster Health
talosctl --talosconfig _out\talosconfig health
```

### Common Operations
```powershell
# Add control plane
.\scale-add-node.ps1 -NodeType controlplane

# Add worker
.\scale-add-node.ps1 -NodeType worker

# Remove node (by k8s name)
.\scale-remove-node.ps1 -NodeName talos-xyz-abc

# Remove node (by VM name)
.\scale-remove-node.ps1 -NodeName talos-hypv-worker-02

# Force removal (skip prompts)
.\scale-remove-node.ps1 -NodeName <name> -Force

# Complete cluster teardown
.\destroy-cluster.ps1
```

## Troubleshooting

### VM won't get IP
1. Check Hyper-V Default Switch exists: `Get-VMSwitch`
2. Check VM network adapter: `Get-VMNetworkAdapter -VMName <name>`
3. Check MAC address: Should not be `000000000000`
4. Check ARP table: `Get-NetNeighbor | Where-Object LinkLayerAddress -like '*-*-*'`

### etcd member not joining
1. Verify control-plane config: `Get-Content _out\controlplane.yaml`
2. Check etcd members: `talosctl -n <cp-ip> etcd members`
3. Check node logs: `talosctl -n <node-ip> logs etcd`
4. Verify cluster endpoint in config matches actual CP IP

### Node stuck in NotReady
1. Wait 2-3 minutes (normal bootstrap time)
2. Check pod status: `kubectl get pods -n kube-system`
3. Check Talos logs: `talosctl -n <node-ip> dmesg`
4. Check CNI (Flannel): `kubectl logs -n kube-system -l app=flannel`

### Script fails with "connection refused"
1. IP likely changed after reboot
2. Check VM console for actual IP
3. Re-run IP detection manually:
   ```powershell
   $adapter = Get-VMNetworkAdapter -VMName <name>
   $rawMac = $adapter.MacAddress
   $mac = ($rawMac -replace '(.{2})', '$1-').TrimEnd('-')
   Get-NetNeighbor -LinkLayerAddress $mac | Where-Object AddressFamily -eq IPv4
   ```

## Success Criteria

A successful autonomous run should:
1. ✅ Create cluster without errors
2. ✅ All nodes reach Ready state
3. ✅ etcd members match control-plane count
4. ✅ Add/remove operations complete cleanly
5. ✅ Last-node protection triggers
6. ✅ Destroy removes all VMs and configs

**Expected output:** No errors, clear progress messages, proper cleanup.

---

*Last updated: 2026-02-16*
*Session commits: 10*
*Production-ready: Yes ✅*
