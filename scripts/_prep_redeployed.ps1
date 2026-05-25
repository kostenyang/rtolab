<#  After golden-OVA redeploy, per nested ESXi host (one GuestOps call):
      - vmk0: remove/re-add (fresh unique MAC) + correct per-host IP (3-step)
      - hostname / DNS
      - touch /etc/rtolab-configured  -> golden-OVA local.sh stops forcing .14
      - LAST: set a unique /system/uuid in esx.conf + auto-backup
    then HARD power-cycle (Stop-Kill + Start) so esx.conf from bootbank wins
    and ESXi comes up with the unique UUID. #>
param([string[]]$Only=@('esx01','esx02','esx03','esx04'))
$ErrorActionPreference='Stop'
$repoRoot='c:\Users\Administrator\rtolab'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$inv=Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets=Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null
$si=Get-View ServiceInstance
$gom=Get-View $si.Content.GuestOperationsManager
$pm=Get-View $gom.ProcessManager
$fm=Get-View $gom.FileManager
$auth=New-Object VMware.Vim.NamePasswordAuthentication -Property @{Username='root';Password=$secrets.esxi.root_pw;InteractiveSession=$false}
# unique system UUID per host (base = the cloned shared UUID, last octet made distinct)
$uuidMap=@{esx01='6a0b15a2-5431-bdcd-22b1-005056a58f01';esx02='6a0b15a2-5431-bdcd-22b1-005056a58f02';esx03='6a0b15a2-5431-bdcd-22b1-005056a58f03';esx04='6a0b15a2-5431-bdcd-22b1-005056a58f04'}

function Run-Guest($moref,[string]$script){
  try{
    $tmp=New-TemporaryFile
    Set-Content -Path $tmp -Value ("#!/bin/sh`n$script`n") -Encoding UTF8 -NoNewline
    $bytes=[IO.File]::ReadAllBytes($tmp); Remove-Item $tmp -Force
    $attr=New-Object VMware.Vim.GuestFileAttributes
    $url=$fm.InitiateFileTransferToGuest($moref,$auth,'/tmp/prep.sh',$attr,$bytes.Length,$true)
    Invoke-WebRequest -Uri $url -Method Put -Body $bytes -ContentType 'application/octet-stream' -SkipCertificateCheck -UseBasicParsing | Out-Null
    $spec=New-Object VMware.Vim.GuestProgramSpec -Property @{ProgramPath='/bin/sh';Arguments='-c "/bin/sh /tmp/prep.sh > /tmp/prep.out 2>&1"'}
    $gpid=$pm.StartProgramInGuest($moref,$auth,$spec)
    for($i=0;$i -lt 120;$i++){ try{$p=$pm.ListProcessesInGuest($moref,$auth,@($gpid)); if($p[0].EndTime){break}}catch{break}; Start-Sleep 1 }
    Start-Sleep 3
    $info=$fm.InitiateFileTransferFromGuest($moref,$auth,'/tmp/prep.out')
    $r=Invoke-WebRequest -Uri $info.Url -SkipCertificateCheck -UseBasicParsing
    return [System.Text.Encoding]::UTF8.GetString($r.Content)
  }catch{ return "(output retrieval failed: $($_.Exception.Message) - script likely still ran)" }
}

foreach($h in $inv.hosts_by_version.'9.1'){
  $short=$h.name.Split('-')[-1]
  if($Only -notcontains $short){ continue }
  $vmName=$h.nested_vm_name
  $vm=Get-VM -Name $vmName -ErrorAction SilentlyContinue
  if(-not $vm){ Write-Host "$vmName not found"; continue }
  Write-Host ""
  Write-Host "=== $vmName -> $($h.mgmt_ip)  uuid=$($uuidMap[$short]) ===" -ForegroundColor Cyan
  $mo=$vm.ExtensionData.MoRef
  $gw=[string]$inv.network.mgmt.gateway
  $dns=[string]$inv.infra.ad_dns.ip
  $shortHost=$h.fqdn.Split('.')[0]
  $script=@"
set -x
# vmk0: remove + re-add (fresh unique MAC), then 3-step IP
esxcli network ip interface remove --interface-name=vmk0
esxcli network ip interface add --interface-name=vmk0 --portgroup-name='Management Network'
esxcli network ip interface ipv4 set -i vmk0 -t static -I $($h.mgmt_ip) -N 255.255.255.0
esxcli network ip route ipv4 add --gateway $gw --network default
esxcli network ip interface ipv4 set -i vmk0 -t static -I $($h.mgmt_ip) -N 255.255.255.0 -g $gw
esxcli system hostname set --host=$shortHost
esxcli system hostname set --fqdn=$($h.fqdn)
esxcli system hostname set --domain=$($inv.lab.domain)
esxcli network ip dns server remove --all 2>/dev/null
esxcli network ip dns server add --server=$dns
# marker so golden-OVA local.sh stops re-forcing .14
touch /etc/rtolab-configured
# LAST: unique system UUID (do this right before auto-backup, no esxcli after)
grep -v '^/system/uuid' /etc/vmware/esx.conf > /tmp/ec
echo '/system/uuid = "$($uuidMap[$short])"' >> /tmp/ec
cat /tmp/ec > /etc/vmware/esx.conf
/sbin/auto-backup.sh
echo PREP-DONE uuid=`$(grep '^/system/uuid' /etc/vmware/esx.conf)
"@
  Write-Host (Run-Guest $mo $script)
  Write-Host "  hard power-cycle $vmName ..."
  Stop-VM -VM (Get-VM -Name $vmName) -Kill -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
  Start-Sleep 5
  Start-VM -VM (Get-VM -Name $vmName) -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
  Write-Host "  $vmName power-cycled"
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Write-Host ""
Write-Host "done. hosts booting -> unique UUID + correct per-host IP. wait ~3 min, verify." -ForegroundColor Cyan
