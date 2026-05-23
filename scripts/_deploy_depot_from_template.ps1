$ProgressPreference='SilentlyContinue'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$repoRoot = 'c:\Users\Administrator\rtolab'
$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null

$vmName = 'rtolab-depotsrv'
$old = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if ($old) {
  if ($old.PowerState -eq 'PoweredOn') { Stop-VM -VM $old -Kill -Confirm:$false | Out-Null; Start-Sleep 3 }
  Remove-VM -VM $old -DeletePermanently -Confirm:$false
}

$spec   = Get-OSCustomizationSpec -Name 'linux'
Write-Host "using customization spec 'linux'"
# show + set NIC mapping to static 172.16.10.50
$nic = Get-OSCustomizationNicMapping -OSCustomizationSpec $spec
Write-Host "  current NIC IpMode: $($nic.IpMode)"
try {
  $nic | Set-OSCustomizationNicMapping -IpMode UseStaticIP `
     -IpAddress '172.16.10.50' -SubnetMask '255.255.255.0' -DefaultGateway '172.16.10.254' | Out-Null
  Write-Host "  NIC set to static 172.16.10.50"
} catch { Write-Host "  NIC set note: $($_.Exception.Message)" }

$tpl    = Get-Template -Name 'rtolab-depot'
$vmhost = Get-VMHost -Name '172.16.10.1'
$ds     = Get-Datastore -Name 'esxi-vol3'

# VM folder for this session's VMs
$dc = Get-Datacenter | Select-Object -First 1
$vmRoot = Get-Folder -Name 'vm' -Location $dc -Type VM | Select-Object -First 1
$folder = Get-Folder -Name 'rtolab-vcf91' -ErrorAction SilentlyContinue
if (-not $folder) { $folder = New-Folder -Name 'rtolab-vcf91' -Location $vmRoot; Write-Host "created VM folder 'rtolab-vcf91'" }

Write-Host "deploying $vmName from template 'rtolab-depot' with 'linux' customization..."
$vm = New-VM -Name $vmName -Template $tpl -VMHost $vmhost -Datastore $ds -OSCustomizationSpec $spec -Location $folder -ErrorAction Stop
$pg = Get-VirtualPortGroup -VMHost $vmhost -Name 'selab-sswitch-pg-management' -Standard
Get-NetworkAdapter -VM $vm | Set-NetworkAdapter -Portgroup $pg -Confirm:$false | Out-Null
Set-VM -VM $vm -MemoryGB 8 -NumCpu 4 -Confirm:$false | Out-Null
Start-VM -VM $vm -Confirm:$false | Out-Null
Write-Host "$vmName powered on -> 172.16.10.50 (folder rtolab-vcf91)"
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
