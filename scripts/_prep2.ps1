<#  Correct prep for golden-OVA redeployed nested ESXi 9.1 hosts.
    Phase 1 (GuestOps - network esxcli only): enable SSH + vmk0 remove/re-add
            (fresh unique MAC) + per-host IP + hostname + DNS.
    Phase 2 (SSH - real root, GuestOps is sandboxed on ESXi 9.x): marker file +
            unique /system/uuid in esx.conf + auto-backup (persist to bootbank).
    Phase 3: HARD power-cycle (Stop-Kill + Start) so bootbank esx.conf wins. #>
param([string[]]$Only=@('esx01','esx02','esx03','esx04'))
$ErrorActionPreference='Stop'
$repoRoot='c:\Users\Administrator\rtolab'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Import-Module Posh-SSH
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$inv=Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets=Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null
$si=Get-View ServiceInstance
$gom=Get-View $si.Content.GuestOperationsManager
$pm=Get-View $gom.ProcessManager
$fm=Get-View $gom.FileManager
$auth=New-Object VMware.Vim.NamePasswordAuthentication -Property @{Username='root';Password=$secrets.esxi.root_pw;InteractiveSession=$false}
$rootPw=$secrets.esxi.root_pw
$gw=[string]$inv.network.mgmt.gateway
$dns=[string]$inv.infra.ad_dns.ip
$uuidMap=@{esx01='6a0b15a2-5431-bdcd-22b1-005056a58f01';esx02='6a0b15a2-5431-bdcd-22b1-005056a58f02';esx03='6a0b15a2-5431-bdcd-22b1-005056a58f03';esx04='6a0b15a2-5431-bdcd-22b1-005056a58f04'}

function Guest-Run($moref,[string]$script){
  $tmp=New-TemporaryFile
  Set-Content -Path $tmp -Value ("#!/bin/sh`n$script`n") -Encoding UTF8 -NoNewline
  $bytes=[IO.File]::ReadAllBytes($tmp); Remove-Item $tmp -Force
  $attr=New-Object VMware.Vim.GuestFileAttributes
  $url=$fm.InitiateFileTransferToGuest($moref,$auth,'/tmp/p1.sh',$attr,$bytes.Length,$true)
  Invoke-WebRequest -Uri $url -Method Put -Body $bytes -ContentType 'application/octet-stream' -SkipCertificateCheck -UseBasicParsing | Out-Null
  $spec=New-Object VMware.Vim.GuestProgramSpec -Property @{ProgramPath='/bin/sh';Arguments='-c "/bin/sh /tmp/p1.sh > /tmp/p1.out 2>&1"'}
  $gpid=$pm.StartProgramInGuest($moref,$auth,$spec)
  for($i=0;$i -lt 120;$i++){ try{$p=$pm.ListProcessesInGuest($moref,$auth,@($gpid)); if($p[0].EndTime){break}}catch{break}; Start-Sleep 1 }
  try{ Start-Sleep 2; $info=$fm.InitiateFileTransferFromGuest($moref,$auth,'/tmp/p1.out')
       $r=Invoke-WebRequest -Uri $info.Url -SkipCertificateCheck -UseBasicParsing
       [System.Text.Encoding]::UTF8.GetString($r.Content) }catch{ '(output retrieval failed)' }
}

$targets=@()
foreach($h in $inv.hosts_by_version.'9.1'){
  $short=$h.name.Split('-')[-1]
  if($Only -notcontains $short){ continue }
  $targets+=[pscustomobject]@{short=$short;h=$h;vm=(Get-VM -Name $h.nested_vm_name)}
}

# ---- PHASE 1: GuestOps - enable SSH + vmk0 + IP + hostname + DNS ----
foreach($t in $targets){
  Write-Host ""
  Write-Host "=== PHASE1 $($t.vm.Name) -> $($t.h.mgmt_ip) ===" -ForegroundColor Cyan
  $shortHost=$t.h.fqdn.Split('.')[0]
  $p1=@"
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
esxcli network ip interface remove --interface-name=vmk0
esxcli network ip interface add --interface-name=vmk0 --portgroup-name='Management Network'
esxcli network ip interface ipv4 set -i vmk0 -t static -I $($t.h.mgmt_ip) -N 255.255.255.0
esxcli network ip route ipv4 add --gateway $gw --network default
esxcli network ip interface ipv4 set -i vmk0 -t static -I $($t.h.mgmt_ip) -N 255.255.255.0 -g $gw
esxcli system hostname set --host=$shortHost
esxcli system hostname set --fqdn=$($t.h.fqdn)
esxcli system hostname set --domain=$($inv.lab.domain)
esxcli network ip dns server remove --all 2>/dev/null
esxcli network ip dns server add --server=$dns
echo P1-DONE
esxcli network ip interface ipv4 address list | grep vmk0
"@
  Write-Host (Guest-Run $t.vm.ExtensionData.MoRef $p1)
}

Write-Host ""
Write-Host "waiting 30s for hosts to settle on new IPs..." -ForegroundColor DarkGray
Start-Sleep 30

# ---- PHASE 2: SSH - marker + unique UUID + persist ----
$sec=ConvertTo-SecureString $rootPw -AsPlainText -Force
$cred=New-Object System.Management.Automation.PSCredential('root',$sec)
foreach($t in $targets){
  Write-Host ""
  Write-Host "=== PHASE2 (SSH) $($t.vm.Name) @ $($t.h.mgmt_ip) ===" -ForegroundColor Cyan
  $uuid=$uuidMap[$t.short]
  $ok=$false
  for($try=1;$try -le 6 -and -not $ok;$try++){
    try{
      $s=New-SSHSession -ComputerName $t.h.mgmt_ip -Credential $cred -AcceptKey -ConnectionTimeout 20 -Force
      $cmd="touch /etc/rtolab-configured && echo marker-ok; grep -v '^/system/uuid' /etc/vmware/esx.conf > /tmp/ec && echo '/system/uuid = `"$uuid`"' >> /tmp/ec && cp /tmp/ec /etc/vmware/esx.conf && echo uuid-set; /sbin/auto-backup.sh > /dev/null 2>&1 && echo backup-ok; grep '^/system/uuid' /etc/vmware/esx.conf"
      $r=Invoke-SSHCommand -SSHSession $s -Command $cmd -TimeOut 90
      Write-Host ($r.Output -join "`n")
      Remove-SSHSession -SSHSession $s | Out-Null
      $ok=$true
    }catch{ Write-Host "  SSH try ${try}: $($_.Exception.Message)"; Start-Sleep 15 }
  }
  if(-not $ok){ Write-Host "  PHASE2 FAILED for $($t.vm.Name)" -ForegroundColor Red }
}

# ---- PHASE 3: HARD power-cycle ----
foreach($t in $targets){
  Write-Host "  hard power-cycle $($t.vm.Name)..."
  Stop-VM -VM (Get-VM -Name $t.vm.Name) -Kill -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
Start-Sleep 6
foreach($t in $targets){
  Start-VM -VM (Get-VM -Name $t.vm.Name) -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Write-Host ""
Write-Host "done. hosts booting -> unique UUID + correct per-host IP. wait ~3 min, verify." -ForegroundColor Cyan
