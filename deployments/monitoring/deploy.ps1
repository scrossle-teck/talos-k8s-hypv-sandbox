<#
.SYNOPSIS
    Deploys kube-prometheus-stack on the Talos cluster.
.DESCRIPTION
    Installs Prometheus, Grafana, and node-exporter via the kube-prometheus-stack
    Helm chart. Sized for a laptop sandbox (512Mi-1Gi Prometheus, 7d retention).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Kubeconfig  = Join-Path $RepoRoot '_out' 'kubeconfig'
$ValuesFile  = Join-Path $PSScriptRoot 'kube-prometheus-values.yaml'

function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }

# ── Preflight ─────────────────────────────────────────────────────────────────

Write-Step 'Checking prerequisites'

if (-not (Test-Path $Kubeconfig)) { throw "kubeconfig not found at $Kubeconfig" }
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) { throw 'helm not found in PATH.' }

$env:KUBECONFIG = $Kubeconfig

# ── Create namespace with privileged label ────────────────────────────────────

Write-Step 'Creating monitoring namespace with privileged PSA label'

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
kubectl label namespace monitoring pod-security.kubernetes.io/enforce=privileged --overwrite

# ── Install kube-prometheus-stack ─────────────────────────────────────────────

Write-Step 'Adding prometheus-community Helm repo and installing kube-prometheus-stack'

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>&1 | Out-Null
helm repo update prometheus-community 2>&1 | Out-Null

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack `
    --namespace monitoring `
    --values $ValuesFile `
    --wait `
    --timeout 10m

if ($LASTEXITCODE -ne 0) { throw 'kube-prometheus-stack Helm install failed.' }

# ── Verify ────────────────────────────────────────────────────────────────────

Write-Step 'Verifying monitoring pods'

kubectl -n monitoring get pods

Write-Host "`n" -NoNewline
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  Monitoring stack deployed successfully!' -ForegroundColor Green
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  Grafana:    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80' -ForegroundColor Yellow
Write-Host '  Prometheus: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090' -ForegroundColor Yellow
Write-Host '  Login:      admin / admin' -ForegroundColor Yellow
Write-Host ''
