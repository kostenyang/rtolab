[CmdletBinding()]
param([switch]$Apply, [string[]]$Names)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$inv = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null

$vms = Get-VM
Write-Host ""
Write-Host "=== VMs with ConsolidationNeeded = TRUE ===" -ForegroundColor Cyan
$need = $vms | Where-Object { $_.ExtensionData.Runtime.ConsolidationNeeded -eq $true }
if (-not $need) { Write-Host "  (none)" -ForegroundColor Green }
foreach ($vm in $need) {
    Write-Host ("  {0}  [{1}]" -f $vm.Name, $vm.PowerState) -ForegroundColor Yellow
}

Write-Host ("DEBUG: Apply={0}  Names=[{1}]" -f $Apply, ($Names -join ',')) -ForegroundColor DarkGray
if ($Apply) {
    $target = $need
    if ($Names) { $target = $need | Where-Object { $_.Name -in $Names } }
    Write-Host ("DEBUG: target count = {0}" -f @($target).Count) -ForegroundColor DarkGray
    foreach ($vm in $target) {
        Write-Host ""
        Write-Host "=== Consolidate: $($vm.Name) ===" -ForegroundColor Cyan
        $task = $vm.ExtensionData.ConsolidateVMDisks_Task()
        $tv = Get-View $task
        $lastPct = -1
        while ($tv.Info.State -in 'running','queued') {
            Start-Sleep 15
            # Long-running consolidate: vCenter SDK can briefly drop. Retry the
            # poll a few times before giving up so a transient blip doesn't
            # abort an in-flight task.
            $polled = $false
            for ($i = 0; $i -lt 6 -and -not $polled; $i++) {
                try { $tv.UpdateViewData('Info.State','Info.Progress','Info.Error'); $polled = $true }
                catch { Write-Warning ("  poll retry {0}/6: {1}" -f ($i+1), $_.Exception.Message); Start-Sleep 30 }
            }
            if (-not $polled) { Write-Warning "  vCenter unreachable for >3 min; aborting watch (task may still finish server-side)"; break }
            if ($tv.Info.Progress -and $tv.Info.Progress -ne $lastPct) {
                Write-Host ("  {0}%" -f $tv.Info.Progress); $lastPct = $tv.Info.Progress
            }
        }
        if ($tv.Info.State -eq 'success') { Write-Host "  done" -ForegroundColor Green }
        elseif ($tv.Info.State -in 'running','queued') { Write-Host "  (still running server-side; re-run script later to verify)" -ForegroundColor Yellow }
        else { Write-Warning "  $($tv.Info.Error.LocalizedMessage)" }
    }
}

Disconnect-VIServer * -Confirm:$false -Force | Out-Null
