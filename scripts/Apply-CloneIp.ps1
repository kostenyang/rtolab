<#
.SYNOPSIS
    給 nested ESXi clone (vmk0 MAC 已修正過) 用 GuestOps API 套靜態 IP/hostname/DNS/route.
    分開 Fix-CloneNetwork 是因為 remove/add vmk0 後 ipv4 set 有時要重試.

.PARAMETER Versions / Hosts
    同 Fix-CloneNetwork.
#>
[CmdletBinding()]
param(
    [string[]] $Versions = @('9.0','9.1','5.2.1'),
    [string[]] $Hosts    = @('esx02','esx03','esx04')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

Connect-VIServer $inv.infra.outer_vcenter.fqdn `
    -User $inv.infra.outer_vcenter.user `
    -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null

$si  = Get-View ServiceInstance
$gom = Get-View $si.Content.GuestOperationsManager
$pm  = Get-View $gom.ProcessManager
$fm  = Get-View $gom.FileManager

$guestAuth = New-Object VMware.Vim.NamePasswordAuthentication -Property @{
    Username = 'root'; Password = $secrets.esxi.root_pw; InteractiveSession = $false
}

foreach ($v in $Versions) {
    foreach ($h in $inv.hosts_by_version[$v]) {
        $shortName = $h.name.Split('-')[-1]
        if ($Hosts -notcontains $shortName) { continue }
        $vmName = $h.nested_vm_name
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) { continue }
        if ($vm.PowerState -ne 'PoweredOn') { Write-Host "[skip] $vmName not on"; continue }

        Write-Host ""
        Write-Host "=== $v / $vmName -> $($h.mgmt_ip) ===" -ForegroundColor Cyan

        $sh = @"
#!/bin/sh
set -x
IP='$($h.mgmt_ip)'
NETMASK='255.255.255.0'
GW='$($inv.network.mgmt.gateway)'
DNS='$($inv.infra.ad_dns.ip)'
DOMAIN='$($inv.lab.domain)'
HOSTNAME='$($h.fqdn)'

# 兩段式: 先 set IP 不帶 gateway (避開 'netstack default gateway not configured' chicken-egg),
# 再 add default route, 最後重 set 帶 gateway 把 interface gateway 字段也寫進去
esxcli network ip interface ipv4 set -i vmk0 -t static -I "`$IP" -N "`$NETMASK"
esxcli network ip route ipv4 add --gateway "`$GW" --network default
esxcli network ip interface ipv4 set -i vmk0 -t static -I "`$IP" -N "`$NETMASK" -g "`$GW"

# Set both short host and FQDN (ESXi 9.x 兩個欄位是分開的, --fqdn 不會同步 host)
SHORT=`$(echo "`$HOSTNAME" | cut -d. -f1)
esxcli system hostname set --host="`$SHORT" 2>/dev/null
esxcli system hostname set --fqdn="`$HOSTNAME" 2>/dev/null
esxcli system hostname set --domain="`$DOMAIN" 2>/dev/null

esxcli network ip dns server remove --all 2>/dev/null
esxcli network ip dns server add --server="`$DNS"
esxcli network ip dns search add --domain="`$DOMAIN" 2>/dev/null

# 確認
esxcli network ip interface ipv4 get
ping -c 1 -W 2 "`$GW" || echo "ping fail"

touch /etc/rtolab-configured
/sbin/auto-backup.sh

echo DONE
"@
        $tmp = New-TemporaryFile
        Set-Content -Path $tmp -Value $sh -Encoding UTF8 -NoNewline
        $bytes = [IO.File]::ReadAllBytes($tmp)
        $attr = New-Object VMware.Vim.GuestFileAttributes
        $url = $fm.InitiateFileTransferToGuest($vm.ExtensionData.MoRef, $guestAuth, '/tmp/rtolab-ip.sh', $attr, $bytes.Length, $true)
        Invoke-WebRequest -Uri $url -Method Put -Body $bytes -ContentType 'application/octet-stream' -SkipCertificateCheck -UseBasicParsing | Out-Null
        Remove-Item $tmp -Force

        $spec = New-Object VMware.Vim.GuestProgramSpec -Property @{
            ProgramPath = '/bin/sh'
            Arguments = '-c "chmod +x /tmp/rtolab-ip.sh && /bin/sh /tmp/rtolab-ip.sh > /tmp/rtolab-ip.out 2>&1"'
            WorkingDirectory = '/tmp'
        }
        $gpid = $pm.StartProgramInGuest($vm.ExtensionData.MoRef, $guestAuth, $spec)
        for ($i = 0; $i -lt 60; $i++) {
            $p = $pm.ListProcessesInGuest($vm.ExtensionData.MoRef, $guestAuth, @($gpid))
            if ($p[0].EndTime) { break }
            Start-Sleep 1
        }
        $info = $fm.InitiateFileTransferFromGuest($vm.ExtensionData.MoRef, $guestAuth, '/tmp/rtolab-ip.out')
        $r = Invoke-WebRequest -Uri $info.Url -SkipCertificateCheck -UseBasicParsing
        # tool returns bytes — decode as UTF8
        $text = [System.Text.Encoding]::UTF8.GetString($r.Content)
        $tail = ($text -split "`n") | Select-Object -Last 12
        Write-Host "  ---- tail of rtolab-ip.out ----"
        $tail | ForEach-Object { Write-Host "    $_" }

        Start-Sleep 2
        if (Test-Connection -ComputerName $h.mgmt_ip -Count 1 -Quiet -TimeoutSeconds 2) {
            Write-Host "  ✓ $vmName reachable at $($h.mgmt_ip)" -ForegroundColor Green
        } else {
            Write-Warning "  $vmName still unreachable at $($h.mgmt_ip)"
        }
    }
}

Disconnect-VIServer * -Confirm:$false -Force | Out-Null
