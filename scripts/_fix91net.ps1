$ProgressPreference='SilentlyContinue'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$repoRoot = 'c:\Users\Administrator\rtolab'
$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null

$si  = Get-View ServiceInstance
$gom = Get-View $si.Content.GuestOperationsManager
$pm  = Get-View $gom.ProcessManager
$fm  = Get-View $gom.FileManager
$auth = New-Object VMware.Vim.NamePasswordAuthentication -Property @{ Username='root'; Password=$secrets.esxi.root_pw; InteractiveSession=$false }

$hosts = @(
  @{ VM='vcf-m02-esx02-91'; IP='192.168.114.15'; FQDN='kosten-vcf91-esx02.rtolab.local' },
  @{ VM='vcf-m02-esx03-91'; IP='192.168.114.16'; FQDN='kosten-vcf91-esx03.rtolab.local' },
  @{ VM='vcf-m02-esx04-91'; IP='192.168.114.17'; FQDN='kosten-vcf91-esx04.rtolab.local' }
)

foreach ($h in $hosts) {
  $vm = Get-VM -Name $h.VM
  Write-Host "=== $($h.VM) -> $($h.IP) ===" -ForegroundColor Cyan
  $sh = @"
#!/bin/sh
set -x
esxcli system settings advanced set -o /Net/FollowHardwareMac -i 1
esxcli network vswitch standard portgroup set -p 'Management Network' --vlan-id=114
MAC=`$(esxcli network nic list | grep '^vmnic0 ' | awk '{print `$8}')
echo "vmnic0 MAC=`$MAC"
esxcli network ip interface remove --interface-name=vmk0 2>/dev/null
esxcli network ip interface add --interface-name=vmk0 --portgroup-name='Management Network' --mac-address="`$MAC"
esxcli network ip interface ipv4 set -i vmk0 -t static -I '$($h.IP)' -N 255.255.255.0
esxcli network ip route ipv4 add --gateway 192.168.114.254 --network default 2>/dev/null
esxcli network ip interface ipv4 set -i vmk0 -t static -I '$($h.IP)' -N 255.255.255.0 -g 192.168.114.254
esxcli system hostname set --fqdn='$($h.FQDN)'
esxcli network ip dns server remove --all 2>/dev/null
esxcli network ip dns server add --server=192.168.114.200
esxcli network ip dns search add --domain=rtolab.local 2>/dev/null
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
esxcli network ip interface ipv4 get
ping -c 2 -W 2 192.168.114.254
echo RESULT_DONE
"@
  $tmp = New-TemporaryFile
  Set-Content -Path $tmp -Value $sh -Encoding ASCII -NoNewline
  $bytes = [IO.File]::ReadAllBytes($tmp)
  $attr = New-Object VMware.Vim.GuestFileAttributes
  $url = $fm.InitiateFileTransferToGuest($vm.ExtensionData.MoRef, $auth, '/tmp/fix91.sh', $attr, $bytes.Length, $true)
  Invoke-WebRequest -Uri $url -Method Put -Body $bytes -ContentType 'application/octet-stream' -SkipCertificateCheck -UseBasicParsing | Out-Null
  Remove-Item $tmp -Force

  $spec = New-Object VMware.Vim.GuestProgramSpec -Property @{
    ProgramPath='/bin/sh'; Arguments='-c "/bin/sh /tmp/fix91.sh > /tmp/fix91.out 2>&1"'; WorkingDirectory='/tmp'
  }
  $gpid = $pm.StartProgramInGuest($vm.ExtensionData.MoRef, $auth, $spec)
  for ($i=0; $i -lt 90; $i++) {
    $p = $pm.ListProcessesInGuest($vm.ExtensionData.MoRef, $auth, @($gpid))
    if ($p[0].EndTime) { break }
    Start-Sleep 1
  }
  $info = $fm.InitiateFileTransferFromGuest($vm.ExtensionData.MoRef, $auth, '/tmp/fix91.out')
  $out = (Invoke-WebRequest -Uri $info.Url -SkipCertificateCheck -UseBasicParsing).Content
  $txt = [System.Text.Encoding]::UTF8.GetString($out)
  ($txt -split "`n") | Select-Object -Last 14 | ForEach-Object { Write-Host "  $_" }
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Write-Host "FIX DONE"
