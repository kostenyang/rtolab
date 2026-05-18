<#
.SYNOPSIS
    透過 GuestOps 看 nested ESXi clone 內部 vmk0 / vmnic0 MAC / arp / route 狀態.
#>
[CmdletBinding()]
param([Parameter(Mandatory=$true)] [string] $VMName)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null
$si  = Get-View ServiceInstance
$gom = Get-View $si.Content.GuestOperationsManager
$pm  = Get-View $gom.ProcessManager
$fm  = Get-View $gom.FileManager

$guestAuth = New-Object VMware.Vim.NamePasswordAuthentication -Property @{
    Username = 'root'
    Password = $secrets.esxi.root_pw
    InteractiveSession = $false
}

$vm = Get-VM -Name $VMName
$mo = $vm.ExtensionData.MoRef

$diag = @'
#!/bin/sh
echo "=== vmnic0 (vNIC HW MAC) ==="
esxcli network nic list | grep -E 'Name|vmnic0'
echo ""
echo "=== vmk0 (kernel interface) ==="
esxcli network ip interface list 2>&1
echo ""
echo "=== vmk0 IPv4 ==="
esxcli network ip interface ipv4 get 2>&1
echo ""
echo "=== Mgmt portgroup VLAN ==="
esxcli network vswitch standard portgroup list 2>&1
echo ""
echo "=== ARP ==="
esxcli network ip neighbor list 2>&1
echo ""
echo "=== Default route ==="
esxcli network ip route ipv4 list 2>&1
echo ""
echo "=== /Net/FollowHardwareMac ==="
esxcli system settings advanced list -o /Net/FollowHardwareMac 2>&1 | grep -E 'Path|Int Value'
echo ""
echo "=== hostname ==="
hostname
echo ""
echo "=== ping gateway 192.168.114.1 (twice) ==="
ping -c 2 192.168.114.1 2>&1 || true
'@

$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $diag -Encoding UTF8 -NoNewline
$bytes = [IO.File]::ReadAllBytes($tmp)
$attr = New-Object VMware.Vim.GuestFileAttributes
$url = $fm.InitiateFileTransferToGuest($mo, $guestAuth, '/tmp/diag.sh', $attr, $bytes.Length, $true)
Invoke-WebRequest -Uri $url -Method Put -Body $bytes -ContentType 'application/octet-stream' -SkipCertificateCheck -UseBasicParsing | Out-Null
Remove-Item $tmp -Force

$spec = New-Object VMware.Vim.GuestProgramSpec -Property @{
    ProgramPath = '/bin/sh'
    Arguments = '-c "chmod +x /tmp/diag.sh && /bin/sh /tmp/diag.sh > /tmp/diag.out 2>&1"'
    WorkingDirectory = '/tmp'
}
$gpid = $pm.StartProgramInGuest($mo, $guestAuth, $spec)
for ($i = 0; $i -lt 60; $i++) {
    $p = $pm.ListProcessesInGuest($mo, $guestAuth, @($gpid))
    if ($p[0].EndTime) { break }
    Start-Sleep 1
}
$info = $fm.InitiateFileTransferFromGuest($mo, $guestAuth, '/tmp/diag.out')
$r = Invoke-WebRequest -Uri $info.Url -SkipCertificateCheck -UseBasicParsing
Write-Host ""
Write-Host "===== $VMName diag.out =====" -ForegroundColor Cyan
$r.Content

Disconnect-VIServer * -Confirm:$false -Force | Out-Null
