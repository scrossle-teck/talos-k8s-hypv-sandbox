<#
.SYNOPSIS
    Deploys IngressRoutes and configures local DNS for sandbox dashboard access.
.DESCRIPTION
    Creates Traefik IngressRoutes for Grafana, Prometheus, and Hubble UI,
    then adds entries to the Windows hosts file for *.talos.local hostnames.
    After running this, access dashboards at http://<name>.talos.local:30080
#>
#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Kubeconfig  = Join-Path $RepoRoot '_out' 'kubeconfig'
$Manifest    = Join-Path $PSScriptRoot 'ingressroutes.yaml'

function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }

# ── Preflight ─────────────────────────────────────────────────────────────────

Write-Step 'Checking prerequisites'

if (-not (Test-Path $Kubeconfig)) { throw "kubeconfig not found at $Kubeconfig" }
$env:KUBECONFIG = $Kubeconfig

# ── Apply IngressRoutes ───────────────────────────────────────────────────────

Write-Step 'Applying IngressRoutes'

kubectl apply -f $Manifest
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply IngressRoutes.' }
Write-Ok 'IngressRoutes created'

# ── Update hosts file ─────────────────────────────────────────────────────────

Write-Step 'Updating Windows hosts file'

$nodeIp = kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$marker = '# talos-sandbox-ingress'

$hostnames = @(
    'grafana.talos.local',
    'prometheus.talos.local',
    'hubble.talos.local'
)

# Remove old entries
$content = Get-Content $hostsFile | Where-Object { $_ -notmatch $marker }

# Add new entries
foreach ($hostname in $hostnames) {
    $content += "$nodeIp  $hostname  $marker"
}

Set-Content -Path $hostsFile -Value $content
Write-Ok "Hosts file updated (pointing to $nodeIp)"

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host "`n" -NoNewline
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  IngressRoutes configured!' -ForegroundColor Green
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host "  Grafana:    http://grafana.talos.local:30080" -ForegroundColor Yellow
Write-Host "  Prometheus: http://prometheus.talos.local:30080" -ForegroundColor Yellow
Write-Host "  Hubble UI:  http://hubble.talos.local:30080" -ForegroundColor Yellow
Write-Host ''
