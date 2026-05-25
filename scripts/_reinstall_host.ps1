<#  Reinstall ESXi on a nested host VM from its kickstart ISO, wait for it to come up. #>
param(
  [Parameter(Mandatory=$true)][string]$VmName,
  [Parameter(Mandatory=$true)][string]$IsoDsPath,
  [Parameter(Mandatory=$true)][string]$MgmtIp,
  [int]$WaitMinutes=30
)
$ErrorActionPreference='Stop'
$repoRoot='c:\Users\Administrator\rtolab'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$inv=Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets=Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null

$vm=Get-VM -Name $VmName -ErrorAction Stop
Write-Host "[$VmName] power=$($vm.PowerState)"
if($vm.PowerState -eq 'PoweredOn'){ Stop-VM -VM $vm -Kill -Confirm:$false | Out-Null; Start-Sleep 4 }
$vm=Get-VM -Name $VmName

# attach kickstart ISO
$cd=Get-CDDrive -VM $vm
if(-not $cd){ $cd=New-CDDrive -VM $vm -Confirm:$false }
Set-CDDrive -CD $cd -IsoPath $IsoDsPath -StartConnected:$true -Confirm:$false | Out-Null
Write-Host "[$VmName] ISO attached: $IsoDsPath"

# boot order -> CDROM first
$spec=New-Object VMware.Vim.VirtualMachineConfigSpec
$bo=New-Object VMware.Vim.VirtualMachineBootOptions
$bo.BootOrder=@((New-Object VMware.Vim.VirtualMachineBootOptionsBootableCdromDevice))
$spec.BootOptions=$bo
$vm.ExtensionData.ReconfigVM($spec)
Write-Host "[$VmName] boot order set CDROM-first"

Start-VM -VM (Get-VM -Name $VmName) -Confirm:$false | Out-Null
Write-Host "[$VmName] powered on -> ESXi kickstart install running..."

# wait for the host to come up on its mgmt IP
$deadline=(Get-Date).AddMinutes($WaitMinutes)
$up=$false
while((Get-Date) -lt $deadline){
  Start-Sleep 30
  if(Test-Connection -ComputerName $MgmtIp -Count 1 -Quiet -ErrorAction SilentlyContinue){
    Start-Sleep 20
    if(Test-Connection -ComputerName $MgmtIp -Count 2 -Quiet -ErrorAction SilentlyContinue){ $up=$true; break }
  }
}
if($up){
  Write-Host "[$VmName] host UP at $MgmtIp"
  # disconnect CD + revert boot order to disk
  $vm=Get-VM -Name $VmName
  Get-CDDrive -VM $vm | Set-CDDrive -NoMedia -Connected:$false -Confirm:$false | Out-Null
  $spec2=New-Object VMware.Vim.VirtualMachineConfigSpec
  $bo2=New-Object VMware.Vim.VirtualMachineBootOptions
  $bo2.BootOrder=@((New-Object VMware.Vim.VirtualMachineBootOptionsBootableDiskDevice))
  $spec2.BootOptions=$bo2
  $vm.ExtensionData.ReconfigVM($spec2)
  Write-Host "[$VmName] CD detached, boot order -> disk. REINSTALL OK"
}else{
  Write-Host "[$VmName] TIMEOUT - host not up after $WaitMinutes min"
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
