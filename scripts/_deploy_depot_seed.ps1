$ProgressPreference='SilentlyContinue'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$repoRoot = 'c:\Users\Administrator\rtolab'
$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null

$vmName = 'rtolab-depotsrv'
$vmhost = Get-VMHost -Name '172.16.10.1'
$ds     = Get-Datastore -Name 'esxi-vol3'

# delete stale VM
$old = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if ($old) {
  Write-Host "deleting stale $vmName ..."
  if ($old.PowerState -eq 'PoweredOn') { Stop-VM -VM $old -Kill -Confirm:$false | Out-Null; Start-Sleep 3 }
  Remove-VM -VM $old -DeletePermanently -Confirm:$false
}

# upload seed ISO to datastore
Write-Host "uploading seed ISO to esxi-vol3..."
$psd = New-PSDrive -Name ds3 -PSProvider VimDatastore -Root '\' -Location $ds -ErrorAction Stop
if (-not (Test-Path 'ds3:\iso')) { New-Item -Path 'ds3:\iso' -ItemType Directory | Out-Null }
Copy-DatastoreItem -Item 'C:\Users\Administrator\rtolab\_seed.iso' -Destination 'ds3:\iso\rtolab-depot-seed.iso' -Force
Remove-PSDrive ds3 -Force
$isoDsPath = '[esxi-vol3] iso/rtolab-depot-seed.iso'

# import OVA fresh
$ova = 'E:\ubuntu-2004-cloud.ova'
$cfg = Get-OvfConfiguration -Ovf $ova
$pg = Get-VirtualPortGroup -VMHost $vmhost -Name 'selab-sswitch-pg-management' -Standard
foreach ($k in ($cfg.ToHashTable().Keys | Where-Object { $_ -like 'NetworkMapping*' })) {
  try { $cfg.$k.Value = $pg } catch {}
}
Write-Host "importing Ubuntu OVA fresh..."
$vm = Import-VApp -Source $ova -OvfConfiguration $cfg -Name $vmName -VMHost $vmhost -Datastore $ds -DiskStorageFormat Thin -Force -ErrorAction Stop

# move to folder
$folder = Get-Folder -Name 'rtolab-vcf91' -Type VM -ErrorAction SilentlyContinue | Select-Object -First 1
if ($folder) { Move-VM -VM (Get-VM -Id $vm.Id) -Destination $folder -Confirm:$false | Out-Null }

# NIC -> mgmt portgroup
Get-NetworkAdapter -VM $vm | Set-NetworkAdapter -Portgroup $pg -Confirm:$false | Out-Null
# RAM/CPU
Set-VM -VM $vm -MemoryGB 8 -NumCpu 4 -Confirm:$false | Out-Null
# disk -> 120GB
$hd = Get-HardDisk -VM (Get-VM -Id $vm.Id) | Select-Object -First 1
if ($hd.CapacityGB -lt 120) { $hd | Set-HardDisk -CapacityGB 120 -Confirm:$false | Out-Null }
# attach seed ISO
$cd = Get-CDDrive -VM (Get-VM -Id $vm.Id)
if (-not $cd) { $cd = New-CDDrive -VM (Get-VM -Id $vm.Id) -Confirm:$false }
Set-CDDrive -CD $cd -IsoPath $isoDsPath -StartConnected:$true -Connected:$true -Confirm:$false | Out-Null

Start-VM -VM (Get-VM -Id $vm.Id) -Confirm:$false | Out-Null
Write-Host "$vmName powered on with seed ISO -> cloud-init sets root/ubuntu=VMware1!VMware1! + IP 172.16.10.50"
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
