<#  Re-deploy nested ESXi 9.1 hosts FRESH from the stock William Lam OVA.
    Fixes duplicate system-UUID (fresh boot -> unique UUID) and vmk0-MAC
    collision (followmac=false). guestinfo passed via ExtraConfig (the
    William Lam appliance first-boot script reads it via vmware-rpctool). #>
param(
  [string[]]$Only = @('esx01','esx02','esx03','esx04')
)
$ErrorActionPreference='Stop'
$repoRoot='c:\Users\Administrator\rtolab'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$inv=Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets=Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null

$ova='E:/custom-ova/rtolab-nested-esxi9.1.ova'   # custom golden OVA (boots reliably; UUID regenerated post-deploy)
$sizing=$inv.vcf.versions.'9.1'.sizing
$vapp=Get-VApp -Name 'rtolab-vcf91' -ErrorAction SilentlyContinue
# outer host + datastore placement per nested host (each on its own local datastore)
$place=@{
  esx01=@{outerhost='172.16.10.6';ds='vsanDatastore-RTO'}
  esx02=@{outerhost='172.16.10.10';ds='vsanDatastore-RTO'}
  esx03=@{outerhost='172.16.10.7';ds='vsanDatastore-RTO'}
  esx04=@{outerhost='172.16.10.4';ds='vsanDatastore-RTO'}
}

foreach($h in $inv.hosts_by_version.'9.1'){
  $short=$h.name.Split('-')[-1]
  if($Only -notcontains $short){ continue }
  $vmName=$h.nested_vm_name
  Write-Host ""
  Write-Host "=== $vmName -> $($h.mgmt_ip) ($($h.fqdn)) ===" -ForegroundColor Cyan

  $vmhost=Get-VMHost -Name $place[$short].outerhost
  $ds=Get-Datastore -Name $place[$short].ds
  Write-Host "  target: outerhost=$($vmhost.Name) datastore=$($ds.Name)"

  foreach($o in (Get-VM -Name $vmName -ErrorAction SilentlyContinue)){
    if($o.PowerState -eq 'PoweredOn'){ Stop-VM -VM $o -Kill -Confirm:$false -ErrorAction SilentlyContinue | Out-Null; Start-Sleep 3 }
    try { Remove-VM -VM $o -DeletePermanently -Confirm:$false -ErrorAction Stop; Write-Host "  deleted old $($o.Name) [$($o.ExtensionData.MoRef.Value)]" }
    catch { Remove-VM -VM $o -Confirm:$false -ErrorAction SilentlyContinue; Write-Host "  removed-from-inventory $($o.Name) [$($o.ExtensionData.MoRef.Value)] (orphan)" }
  }

  # OVF config: only NetworkMapping needed at import time
  $cfg=Get-OvfConfiguration -Ovf $ova
  $pg=Get-VDPortgroup -Name $inv.infra.deployment.portgroup -ErrorAction SilentlyContinue
  if(-not $pg){ $pg=Get-VirtualPortGroup -VMHost $vmhost -Name $inv.infra.deployment.portgroup -Standard -ErrorAction SilentlyContinue }
  if($cfg.NetworkMapping){
    foreach($nm in $cfg.NetworkMapping.PSObject.Properties){ $nm.Value.Value=$pg }
  }

  Write-Host "  Import-VApp (thin) ..."
  $vm=Import-VApp -Source $ova -OvfConfiguration $cfg -Name $vmName -VMHost $vmhost -Datastore $ds -DiskStorageFormat Thin -Force -ErrorAction Stop

  # guestinfo via ExtraConfig + NestedHV
  $set=[ordered]@{
    'guestinfo.hostname'=$h.fqdn; 'guestinfo.ipaddress'=$h.mgmt_ip
    'guestinfo.netmask'='255.255.255.0'; 'guestinfo.gateway'=[string]$inv.network.mgmt.gateway
    'guestinfo.dns'=[string]$inv.infra.ad_dns.ip; 'guestinfo.domain'=$inv.lab.domain
    'guestinfo.ntp'=[string]$inv.infra.ad_dns.ip; 'guestinfo.password'=$secrets.esxi.root_pw
    'guestinfo.vlan'=[string]$inv.network.mgmt.vlan; 'guestinfo.ssh'='True'
    'guestinfo.createvmfs'='False'; 'guestinfo.followmac'='False'
  }
  $extras=$set.GetEnumerator() | ForEach-Object { New-Object VMware.Vim.OptionValue -Property @{Key=$_.Key;Value=[string]$_.Value} }
  $spec=New-Object VMware.Vim.VirtualMachineConfigSpec -Property @{ ExtraConfig=$extras; NestedHVEnabled=$true }
  (Get-VM -Id $vm.Id).ExtensionData.ReconfigVM($spec)

  Set-VM -VM (Get-VM -Id $vm.Id) -NumCpu $sizing.vcpu -MemoryGB $sizing.memory_gb -Confirm:$false | Out-Null

  $nics=Get-NetworkAdapter -VM (Get-VM -Id $vm.Id)
  $nics | Set-NetworkAdapter -Portgroup $pg -Confirm:$false | Out-Null
  while((Get-NetworkAdapter -VM (Get-VM -Id $vm.Id)).Count -lt 2){
    New-NetworkAdapter -VM (Get-VM -Id $vm.Id) -Portgroup $pg -Type Vmxnet3 -StartConnected -Confirm:$false | Out-Null
  }

  $disks=Get-HardDisk -VM (Get-VM -Id $vm.Id) | Sort-Object {$_.ExtensionData.UnitNumber}
  Write-Host ("  disks before: " + (($disks | ForEach-Object { [int]$_.CapacityGB }) -join 'GB, ') + 'GB  (count=' + $disks.Count + ')')
  $want=@(100,700)
  for($i=1;$i -le 2;$i++){
    if($disks.Count -gt $i){
      if([int]$disks[$i].CapacityGB -lt $want[$i-1]){ $disks[$i] | Set-HardDisk -CapacityGB $want[$i-1] -Confirm:$false | Out-Null }
    } else {
      New-HardDisk -VM (Get-VM -Id $vm.Id) -CapacityGB $want[$i-1] -StorageFormat Thin -Confirm:$false | Out-Null
    }
  }

  if($vapp){ $vapp.ExtensionData.MoveIntoResourcePool(@((Get-VM -Id $vm.Id).ExtensionData.MoRef)) }
  Start-VM -VM (Get-VM -Id $vm.Id) -Confirm:$false | Out-Null
  Write-Host "  done $vmName deployed + powered on"
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Write-Host ""
Write-Host "done. wait ~3 min for ESXi boot + guestinfo IP apply." -ForegroundColor Cyan
