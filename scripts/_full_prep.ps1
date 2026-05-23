<#  Full prep chain for 4 fresh nested ESXi 9.1:
    wait Tools -> _prep2 -> wait IPs -> cert regen (SSH) -> vSAN settings (SSH) -> NTP (PowerCLI). #>
$ErrorActionPreference='Continue'
$repo='c:\Users\Administrator\rtolab'
Import-Module powershell-yaml -ErrorAction SilentlyContinue
Import-Module VMware.VimAutomation.Core -ErrorAction SilentlyContinue
Import-Module Posh-SSH -ErrorAction SilentlyContinue
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$sec=Get-Content -Raw (Join-Path $repo 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
$inv=Get-Content -Raw (Join-Path $repo 'inventory/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $sec.outer_vcenter.sso_admin_pw | Out-Null

$vms='vcf-m02-esx01-91','vcf-m02-esx02-91','vcf-m02-esx03-91','vcf-m02-esx04-91'
$ips ='192.168.114.14','192.168.114.15','192.168.114.16','192.168.114.17'
$fqdns='kosten-vcf91-esx01.rtolab.local','kosten-vcf91-esx02.rtolab.local','kosten-vcf91-esx03.rtolab.local','kosten-vcf91-esx04.rtolab.local'

Write-Host "=== WAIT: VMware Tools on all 4 nested ESXi ==="
for($i=0;$i -lt 60;$i++){
  $ready=$true
  foreach($n in $vms){
    $v=Get-VM -Name $n
    if($v.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning'){ $ready=$false; break }
  }
  if($ready){ Write-Host "  all 4 Tools running after $($i*15)s"; break }
  Start-Sleep 15
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null

Write-Host ""
Write-Host "=== _prep2.ps1 (UUID + vmk0 MAC + per-host IP) ==="
& pwsh -NoProfile -File (Join-Path $repo 'scripts\_prep2.ps1')

Write-Host ""
Write-Host "=== WAIT: all 4 hosts at correct IPs ==="
foreach($ip in $ips){
  for($i=0;$i -lt 40;$i++){
    if(Test-Connection -ComputerName $ip -Count 1 -Quiet -TimeoutSeconds 2){ Write-Host "  $ip UP"; break }
    Start-Sleep 10
  }
}

# Need SSH for next steps; phase-1 enabled it, but power-cycle may have closed.
# We'll re-enable via GuestOps then proceed.
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $sec.outer_vcenter.sso_admin_pw | Out-Null
$si=Get-View ServiceInstance; $pm=Get-View (Get-View $si.Content.GuestOperationsManager).ProcessManager
$auth=New-Object VMware.Vim.NamePasswordAuthentication -Property @{Username='root';Password=$sec.esxi.root_pw;InteractiveSession=$false}
foreach($n in $vms){
  $v=Get-VM -Name $n
  $spec=New-Object VMware.Vim.GuestProgramSpec -Property @{ProgramPath='/bin/sh';Arguments='-c "vim-cmd hostsvc/enable_ssh; vim-cmd hostsvc/start_ssh"'}
  try{ $pm.StartProgramInGuest($v.ExtensionData.MoRef,$auth,$spec) | Out-Null; Write-Host "  SSH re-enabled on $n" }catch{ Write-Host ("  SSH enable on {0}: {1}" -f $n,$_.Exception.Message) }
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Start-Sleep 15

Write-Host ""
Write-Host "=== CERT REGEN via SSH ==="
for($k=0;$k -lt 4;$k++){
  $ip=$ips[$k]; $fqdn=$fqdns[$k]
  Write-Host "--- $ip ($fqdn) ---"
  & pwsh -NoProfile -File (Join-Path $repo 'scripts\_ssh_run.ps1') -Target $ip -Cmd "esxcli system hostname set --fqdn='$fqdn' 2>&1; cd /etc/vmware/ssl && rm -f rui.crt rui.key && /sbin/generate-certificates 2>&1 && /etc/init.d/hostd restart >/dev/null 2>&1 && /etc/init.d/rhttpproxy restart >/dev/null 2>&1 && sleep 3 && openssl x509 -in /etc/vmware/ssl/rui.crt -noout -subject"
}

Write-Host ""
Write-Host "=== vSAN/LSOM 6 settings via SSH ==="
for($k=0;$k -lt 4;$k++){
  $ip=$ips[$k]
  Write-Host "--- $ip ---"
  & pwsh -NoProfile -File (Join-Path $repo 'scripts\_ssh_run.ps1') -Target $ip -Cmd 'for o in /LSOM/VSANDeviceMonitoring:0 /LSOM/lsomSlowDeviceUnmount:0 /VSAN/SwapThickProvisionDisabled:1 /VSAN/Vsan2ZdomCompZstd:0 /VSAN/FakeSCSIReservations:1 /VSAN/GuestUnmap:1; do opt=${o%:*}; val=${o#*:}; esxcli system settings advanced set -o $opt -i $val 2>/dev/null; cur=$(esxcli system settings advanced list -o $opt 2>/dev/null | grep -m1 "Int Value:" | awk "{print \$NF}"); echo "  $opt = $cur"; done'
}

Write-Host ""
Write-Host "=== NTP via PowerCLI (port 443) ==="
& pwsh -NoProfile -File (Join-Path $repo 'scripts\_fix_ntp.ps1')

Write-Host ""
Write-Host "=== FULL PREP DONE ==="
