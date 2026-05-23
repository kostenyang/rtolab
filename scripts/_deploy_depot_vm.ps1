$ProgressPreference='SilentlyContinue'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$repoRoot = 'c:\Users\Administrator\rtolab'
$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null

$vmName = 'rtolab-depot'
$ova = 'E:\ubuntu-2004-cloud.ova'

# wipe any prior attempt
$old = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if ($old) {
  Write-Host "removing prior $vmName ..."
  if ($old.PowerState -eq 'PoweredOn') { Stop-VM -VM $old -Kill -Confirm:$false -ErrorAction SilentlyContinue | Out-Null; Start-Sleep 3 }
  Remove-VM -VM $old -DeletePermanently -Confirm:$false
}

$vmhost = Get-VMHost -Name '172.16.10.1'
$ds = Get-Datastore -Name 'esxi-vol3'
$pg = Get-VirtualPortGroup -VMHost $vmhost -Name 'selab-sswitch-pg-management' -Standard

# import OVA plainly (no OVF props)
$cfg = Get-OvfConfiguration -Ovf $ova
foreach ($k in ($cfg.ToHashTable().Keys | Where-Object { $_ -like 'NetworkMapping*' })) { $cfg.$k.Value = $pg }
Write-Host "Importing Ubuntu depot OVA..."
$vm = Import-VApp -Source $ova -OvfConfiguration $cfg -Name $vmName -VMHost $vmhost -Datastore $ds -DiskStorageFormat Thin -Force -ErrorAction Stop

# cloud-init via guestinfo datasource
$metaData = @"
instance-id: rtolab-depot-001
local-hostname: rtolab-depot
network:
  version: 2
  ethernets:
    ens192:
      dhcp4: false
      addresses: [172.16.10.50/24]
      gateway4: 172.16.10.254
      nameservers:
        addresses: [192.168.114.200, 8.8.8.8]
"@
$userData = @"
#cloud-config
hostname: rtolab-depot
ssh_pwauth: true
disable_root: false
users:
  - name: ubuntu
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
chpasswd:
  expire: false
  list: |
    root:VMware1!VMware1!
    ubuntu:VMware1!VMware1!
"@
$mdB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($metaData))
$udB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userData))
$extra = @(
  @{ Key='guestinfo.metadata';          Value=$mdB64 },
  @{ Key='guestinfo.metadata.encoding'; Value='base64' },
  @{ Key='guestinfo.userdata';          Value=$udB64 },
  @{ Key='guestinfo.userdata.encoding'; Value='base64' }
)
$spec = New-Object VMware.Vim.VirtualMachineConfigSpec -Property @{
  MemoryMB = 8192; NumCPUs = 4
  ExtraConfig = $extra | ForEach-Object { New-Object VMware.Vim.OptionValue -Property $_ }
}
$task = $vm.ExtensionData.ReconfigVM_Task($spec)
$tv = Get-View $task
while ($tv.Info.State -in 'running','queued') { Start-Sleep 1; $tv.UpdateViewData('Info.State','Info.Error') }
if ($tv.Info.State -ne 'success') { throw "Reconfig: $($tv.Info.Error.LocalizedMessage)" }

$hd = Get-HardDisk -VM (Get-VM -Id $vm.Id) | Select-Object -First 1
if ($hd.CapacityGB -lt 120) { $hd | Set-HardDisk -CapacityGB 120 -Confirm:$false | Out-Null; Write-Host "disk -> 120GB" }

Start-VM -VM (Get-VM -Id $vm.Id) -Confirm:$false | Out-Null
Write-Host "rtolab-depot powered on -> 172.16.10.50 (root/ubuntu pw VMware1!VMware1!)"
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
