<#
.SYNOPSIS
    透過 VMware GuestOperationsManager API 強制把 nested ESXi clone 的 vmk0 重新
    bind 到 vNIC 的 HW MAC, 並套上正確 hostname/IP/VLAN/DNS, 然後 /sbin/auto-backup.sh.

.DESCRIPTION
    master state.tgz 內 /etc/vmware/esx.conf 鎖了 master 部署時的 vmk0 MAC, clone
    出來的 VM 雖然有新的 vNIC HW MAC, 但 ESXi 仍然把 vmk0 bind 到舊的 (master's) MAC,
    結果 vmk0 收不到任何 reply -> 不通. /Net/FollowHardwareMac=1 + vmk0 remove/re-add
    可以解開. 因為 clone 不通, 用 GuestOps (VMware Tools 通道) 跑 esxcli.

.PARAMETER Versions
    哪幾版要 fix (預設 9.0, 9.1, 5.2.1 但 5.2.1 此刻 OVA 尚未重做, 自動 skip).

.PARAMETER Hosts
    哪幾台 host (預設 esx02..04). esx01 是 master (template), 不會跑到.
#>

[CmdletBinding()]
param(
    [string[]] $Versions = @('9.0','9.1','5.2.1'),
    [string[]] $Hosts    = @('esx02','esx03','esx04')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

if (-not (Get-Module -ListAvailable powershell-yaml)) { Install-Module powershell-yaml -Scope CurrentUser -Force | Out-Null }
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

Connect-VIServer $inv.infra.outer_vcenter.fqdn `
    -User $inv.infra.outer_vcenter.user `
    -Password $secrets.outer_vcenter.sso_admin_pw -ErrorAction Stop | Out-Null

$si  = Get-View ServiceInstance
$gom = Get-View $si.Content.GuestOperationsManager
$pm  = Get-View $gom.ProcessManager
$fm  = Get-View $gom.FileManager

$rootPw = $secrets.esxi.root_pw
$guestAuth = New-Object VMware.Vim.NamePasswordAuthentication -Property @{
    Username = 'root'
    Password = $rootPw
    InteractiveSession = $false
}

function Invoke-Guest {
    param($Vm, [string]$Cmd)
    $spec = New-Object VMware.Vim.GuestProgramSpec -Property @{
        ProgramPath = '/bin/sh'
        Arguments   = "-c `"$Cmd`""
        WorkingDirectory = '/tmp'
    }
    $gpid = $pm.StartProgramInGuest($Vm.ExtensionData.MoRef, $guestAuth, $spec)
    # 等結束
    for ($i = 0; $i -lt 120; $i++) {
        $procs = $pm.ListProcessesInGuest($Vm.ExtensionData.MoRef, $guestAuth, @($gpid))
        if ($procs[0].EndTime) { return $procs[0] }
        Start-Sleep 1
    }
    Write-Warning "  command timeout: $Cmd"
    return $null
}

function Send-GuestFile {
    param($Vm, [string]$LocalPath, [string]$RemotePath)
    $bytes = [IO.File]::ReadAllBytes($LocalPath)
    $attr = New-Object VMware.Vim.GuestFileAttributes
    $url = $fm.InitiateFileTransferToGuest($Vm.ExtensionData.MoRef, $guestAuth, $RemotePath, $attr, $bytes.Length, $true)
    Invoke-WebRequest -Uri $url -Method Put -Body $bytes -ContentType 'application/octet-stream' -SkipCertificateCheck -UseBasicParsing | Out-Null
}

foreach ($v in $Versions) {
    $vKey  = $v -replace '\.',''
    foreach ($h in $inv.hosts_by_version[$v]) {
        $shortName = $h.name.Split('-')[-1]
        if ($Hosts -notcontains $shortName) { continue }
        $vmName = $h.nested_vm_name
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) { Write-Host "[skip] $vmName not found"; continue }
        if ($vm.PowerState -ne 'PoweredOn') { Write-Host "[skip] $vmName not on (PowerState=$($vm.PowerState))"; continue }
        if (-not $vm.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning') {
            Write-Host "[skip] $vmName Tools not running ($($vm.ExtensionData.Guest.ToolsRunningStatus))"; continue
        }

        Write-Host ""
        Write-Host "=== $v / $vmName -> $($h.mgmt_ip) ===" -ForegroundColor Cyan

        # 建 fix script (傳到 VM /tmp/rtolab-fix.sh, 再跑)
        $fixSh = @"
#!/bin/sh
set -x
HOSTNAME='$($h.fqdn)'
IP='$($h.mgmt_ip)'
NETMASK='255.255.255.0'
GW='$($inv.network.mgmt.gateway)'
VLAN='$($inv.network.mgmt.vlan)'
DNS='$($inv.infra.ad_dns.ip)'
DOMAIN='$($inv.lab.domain)'

# Make ESXi follow vNIC HW MAC after this point (for future reboots)
esxcli system settings advanced set -o /Net/FollowHardwareMac -i 1

# Set VLAN ID on Management Network portgroup (clone inherited 0 from master state)
esxcli network vswitch standard portgroup set -p 'Management Network' --vlan-id="`$VLAN"

# Get vmnic0 HW MAC — explicitly bind vmk0 to it on re-add
VMNIC0_MAC=`$(esxcli network nic list | awk '/vmnic0/{print `$8}')
echo "vmnic0 MAC=`$VMNIC0_MAC"

# Remove vmk0 + re-add with explicit MAC matching vmnic0
esxcli network ip interface remove --interface-name=vmk0
esxcli network ip interface add --interface-name=vmk0 --portgroup-name='Management Network' --mac-address="`$VMNIC0_MAC"

# IPv4 static
esxcli network ip interface ipv4 set -i vmk0 -t static -I "`$IP" -N "`$NETMASK" -g "`$GW"

# default gateway
esxcli network ip route ipv4 add --gateway "`$GW" --network default 2>/dev/null

# Hostname
esxcli system hostname set --fqdn="`$HOSTNAME"

# DNS
esxcli network ip dns server remove --all 2>/dev/null
esxcli network ip dns server add --server="`$DNS"
esxcli network ip dns search add --domain="`$DOMAIN" 2>/dev/null

# Mark configured + persist to boot bank
touch /etc/rtolab-configured
/sbin/auto-backup.sh

echo OK
"@
        $tmpFile = New-TemporaryFile
        try {
            Set-Content -Path $tmpFile.FullName -Value $fixSh -Encoding UTF8 -NoNewline
            Write-Host "  uploading /tmp/rtolab-fix.sh ..."
            Send-GuestFile -Vm $vm -LocalPath $tmpFile.FullName -RemotePath '/tmp/rtolab-fix.sh'
        } finally {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }

        Write-Host "  running /bin/sh /tmp/rtolab-fix.sh ..."
        $r = Invoke-Guest -Vm $vm -Cmd 'chmod +x /tmp/rtolab-fix.sh && /bin/sh /tmp/rtolab-fix.sh > /tmp/rtolab-fix.out 2>&1 ; echo EXIT $?'
        if ($r) {
            Write-Host "    exit=$($r.ExitCode)"
        }

        # 下載 output 看一眼
        try {
            $info = $fm.InitiateFileTransferFromGuest($vm.ExtensionData.MoRef, $guestAuth, '/tmp/rtolab-fix.out')
            $out = Invoke-WebRequest -Uri $info.Url -SkipCertificateCheck -UseBasicParsing
            $tail = ($out.Content -split "`n") | Select-Object -Last 8
            Write-Host "  ---- last 8 lines of fix.out ----"
            $tail | ForEach-Object { Write-Host "    $_" }
            Write-Host "  ---------------------------------"
        } catch {
            Write-Warning "  could not read fix.out: $_"
        }

        Write-Host "  ✓ $vmName fix script done (vmk0 re-bound)" -ForegroundColor Green
    }
}

Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Write-Host ""
Write-Host "完成. 等 ~20 sec 給 vmk0 + ARP 收斂 然後 Test-Connection." -ForegroundColor Cyan
