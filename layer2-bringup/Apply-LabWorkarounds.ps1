<#
.SYNOPSIS
    Apply William Lam's VCF 9.1 lab-deployment configuration workarounds to the
    VCF Installer and SDDC Manager, so a nested lab does not fail bring-up on
    checks/timeouts written for real 10GbE / HCL-certified hardware.

.DESCRIPTION
    Source: williamlam.com — "VCF 9.1 Comprehensive VCF Installer & SDDC Manager
    Configuration Workarounds for Lab Deployments".

    Edits two files, as root, on BOTH appliances:
      /etc/vmware/vcf/domainmanager/application.properties  (validation skips + timeout bumps)
      /home/vcf/feature.properties                          (vSAN ESA managed-disk-claim feature flag)

    Access is via VMware GuestOps (a script run through vCenter VMware Tools), so
    it works even though root SSH is disabled on the appliances. The VCF Installer
    VM lives in the OUTER vCenter; the SDDC Manager VM lives in the INNER vCenter
    deployed by bring-up — the script discovers both.

    Idempotent: an existing key is updated in place, a missing key is appended,
    an already-correct key is left alone. Each file is backed up once per run.

    IMPORTANT: applying these properties only takes effect after domainmanager
    (and, for feature.properties, all VCF services) restart. A restart ABORTS any
    in-progress bring-up. Run this BEFORE submitting bring-up, or while bring-up
    is failed/idle — never mid-run. Without -RestartDomainManager the script only
    stages the files.

.PARAMETER RestartDomainManager
    After staging, run 'systemctl restart domainmanager' on both appliances so the
    application.properties changes take effect.

.PARAMETER RestartAllServices
    Additionally run sddcmanager_restart_services.sh on both appliances so the
    feature.properties change (vSAN ESA HCL feature flag) takes effect. Heavier;
    implies a full VCF services bounce.

.PARAMETER IncludeSingleHost
    Also set feature.vcf.vgl-29121.single.host.domain=true (William Lam #1). Only
    for 1-2 host management domains. OFF by default — this lab has 4 hosts.

.EXAMPLE
    pwsh layer2-bringup/Apply-LabWorkarounds.ps1
    # stage the properties on both appliances, no restart

.EXAMPLE
    pwsh layer2-bringup/Apply-LabWorkarounds.ps1 -RestartDomainManager -RestartAllServices
    # stage + restart so everything takes effect (only when no bring-up is running)
#>
[CmdletBinding()]
param(
    [switch] $RestartDomainManager,
    [switch] $RestartAllServices,
    [switch] $IncludeSingleHost
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml')         | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

# --- William Lam VCF 9.1 lab workarounds -------------------------------------
# domainmanager: /etc/vmware/vcf/domainmanager/application.properties
$dmProps = [ordered]@{
    'enable.speed.of.physical.nics.validation'        = 'false'  # #2  disable 10GbE pNIC check
    'vsan.esa.sddc.managed.disk.claim'                = 'true'   # #3  vSAN ESA HCL: SDDC-managed disk claim
    'validation.disable.vmotion.connectivity.check'   = 'true'   # #4
    'validation.disable.vmotion.l3.gateway.connectivity.check' = 'true'  # #4
    'validation.disable.vsan.connectivity.check'      = 'true'   # #5
    'validation.disable.network.connectivity.check'   = 'true'   # #6  ESX TEP MTU check
    'nsxt.mtu.validation.skip'                        = 'true'   # #6
    'validation.disable.nfs.configuration.connectivity.check' = 'true'  # #7
    'orchestrator.task.retry.max'                     = '5'      # #8  general deployment retry
    'nsxt.manager.wait.minutes'                       = '180'    # #9
    'edge.node.vm.creation.max.wait.minutes'          = '90'     # #10
    'vsp.bootstrap.task.timeout.minutes'              = '240'    # #11 VCF mgmt services bootstrap
    'vsp.bootstrap.command.timeout.minutes'           = '200'    # #11
    'nsxt.alb.image.upload.retry.check.interval.seconds' = '90'  # #12 Avi LB upload
}
# feature flags: /home/vcf/feature.properties
$featProps = [ordered]@{
    'feature.vcf.vgl-43370.vsan.esa.sddc.managed.disk.claim' = 'true'  # #3
}
if ($IncludeSingleHost) {
    $featProps['feature.vcf.vgl-29121.single.host.domain'] = 'true'    # #1
}

# --- build the idempotent bash payload that runs as root on each appliance ---
$lines = @(
    '#!/bin/bash'
    'set -u'
    'AP=/etc/vmware/vcf/domainmanager/application.properties'
    'FP=/home/vcf/feature.properties'
    'TS=$(date +%Y%m%d-%H%M%S)'
    'setprop() {'
    '  local f="$1" k="$2" v="$3" ke'
    '  [ -f "$f" ] || : > "$f"'
    '  ke=$(printf "%s" "$k" | sed "s/[.[\*^$]/\\\\&/g")'
    '  if grep -qE "^[[:space:]]*${ke}[[:space:]]*=" "$f"; then'
    '    if grep -qE "^[[:space:]]*${ke}[[:space:]]*=[[:space:]]*${v}[[:space:]]*$" "$f"; then'
    '      echo "  ok    $k=$v"'
    '    else'
    '      sed -i -E "s|^[[:space:]]*${ke}[[:space:]]*=.*|${k}=${v}|" "$f"'
    '      echo "  upd   $k=$v"'
    '    fi'
    '  else'
    '    printf "%s=%s\n" "$k" "$v" >> "$f"'
    '    echo "  add   $k=$v"'
    '  fi'
    '}'
    '[ -f "$AP" ] && cp -n "$AP" "$AP.bak.$TS"'
    '[ -f "$FP" ] && cp -n "$FP" "$FP.bak.$TS"'
    'echo "== application.properties =="'
)
foreach ($k in $dmProps.Keys) { $lines += ('setprop "$AP" "{0}" "{1}"' -f $k, $dmProps[$k]) }
$lines += 'echo "== feature.properties =="'
foreach ($k in $featProps.Keys) { $lines += ('setprop "$FP" "{0}" "{1}"' -f $k, $featProps[$k]) }
$lines += @(
    '# restore ownership/permissions'
    'if id vcf_domainmanager >/dev/null 2>&1; then chown vcf_domainmanager:vcf "$AP"; fi'
    'chmod 600 "$AP"'
    'if id vcf >/dev/null 2>&1; then chown vcf:vcf "$FP"; fi'
    'chmod 644 "$FP"'
)
if ($RestartDomainManager) {
    $lines += @(
        'echo "== restarting domainmanager =="'
        'systemctl restart domainmanager && echo "  domainmanager restarted" || echo "  domainmanager restart FAILED"'
    )
}
if ($RestartAllServices) {
    $lines += @(
        'echo "== restarting all VCF services =="'
        'R=/opt/vmware/vcf/operationsmanager/scripts/cli/sddcmanager_restart_services.sh'
        '[ -x "$R" ] && echo y | "$R" || echo "  $R not found/!x"'
    )
}
$lines += 'echo "DONE"'
$payload = ($lines -join "`n") + "`n"

# --- GuestOps runner ----------------------------------------------------------
function Invoke-GuestRoot {
    param($VcServer, $VcUser, $VcPass, [string]$VmName, [string]$RootPw, [string]$Script)
    Connect-VIServer $VcServer -User $VcUser -Password $VcPass -ErrorAction Stop | Out-Null
    try {
        $vm = Get-VM -Name $VmName -ErrorAction Stop
        $mo = $vm.ExtensionData.MoRef
        $si = Get-View ServiceInstance
        $gom = Get-View $si.Content.GuestOperationsManager
        $pm = Get-View $gom.ProcessManager
        $fm = Get-View $gom.FileManager
        $auth = New-Object VMware.Vim.NamePasswordAuthentication -Property @{Username='root';Password=$RootPw;InteractiveSession=$false}
        $tmp = New-TemporaryFile
        Set-Content -Path $tmp -Value $Script -Encoding UTF8 -NoNewline
        $bytes = [IO.File]::ReadAllBytes($tmp); Remove-Item $tmp -Force
        $attr = New-Object VMware.Vim.GuestFileAttributes
        $up = $fm.InitiateFileTransferToGuest($mo,$auth,'/tmp/_lwa.sh',$attr,$bytes.Length,$true)
        Invoke-WebRequest -Uri $up -Method Put -Body $bytes -ContentType 'application/octet-stream' -SkipCertificateCheck -UseBasicParsing | Out-Null
        $spec = New-Object VMware.Vim.GuestProgramSpec -Property @{ProgramPath='/bin/bash';Arguments='-c "bash /tmp/_lwa.sh > /tmp/_lwa.out 2>&1"'}
        $gpid = $pm.StartProgramInGuest($mo,$auth,$spec)
        for ($i=0; $i -lt 600; $i++) { $p=$pm.ListProcessesInGuest($mo,$auth,@($gpid)); if ($p[0].EndTime) { break }; Start-Sleep 1 }
        $info = $fm.InitiateFileTransferFromGuest($mo,$auth,'/tmp/_lwa.out')
        $r = Invoke-WebRequest -Uri $info.Url -SkipCertificateCheck -UseBasicParsing
        [System.Text.Encoding]::UTF8.GetString($r.Content)
    } finally { Disconnect-VIServer $VcServer -Confirm:$false -Force | Out-Null }
}

# --- apply to VCF Installer (outer vCenter) ----------------------------------
Write-Host "=== VCF Installer (vcf-installer-91 @ outer vCenter) ===" -ForegroundColor Cyan
Write-Host (Invoke-GuestRoot -VcServer $inv.infra.outer_vcenter.fqdn -VcUser $inv.infra.outer_vcenter.user `
    -VcPass $secrets.outer_vcenter.sso_admin_pw -VmName 'vcf-installer-91' `
    -RootPw $secrets.vcf_installer.root_pw -Script $payload)

# --- apply to SDDC Manager (inner vCenter) -----------------------------------
$v91   = $inv.vcf.versions.'9.1'.management_domain
$innerVc = $v91.inner_vcenter.fqdn
Write-Host "=== SDDC Manager (kosten-vcf91-sddc @ inner vCenter $innerVc) ===" -ForegroundColor Cyan
Write-Host (Invoke-GuestRoot -VcServer $v91.inner_vcenter.ip -VcUser 'administrator@vsphere.local' `
    -VcPass 'VMware1!VMware1!' -VmName 'kosten-vcf91-sddc' `
    -RootPw 'VMware1!VMware1!' -Script $payload)

Write-Host ""
if (-not $RestartDomainManager) {
    Write-Host "Properties STAGED. Re-run with -RestartDomainManager (and -RestartAllServices" -ForegroundColor Yellow
    Write-Host "for the feature flag) to apply — only when no bring-up is in progress." -ForegroundColor Yellow
} else {
    Write-Host "Workarounds applied + services restarted." -ForegroundColor Green
}
