$ErrorActionPreference='Stop'
Import-Module powershell-yaml | Out-Null
Import-Module VMware.VimAutomation.Core | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$repoRoot='c:\Users\Administrator\rtolab'
$inv=Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets=Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

Write-Host '########## INNER vCenter ##########'
Connect-VIServer 192.168.114.11 -User 'administrator@vsphere.local' -Password 'VMware1!VMware1!' | Out-Null
foreach($h in (Get-VMHost | Sort-Object Name)){
  $e=Get-EsxCli -VMHost $h -V2
  $su=$e.system.uuid.get.Invoke()
  $hwuuid=$h.ExtensionData.Hardware.SystemInfo.Uuid
  Write-Host ('  {0}' -f $h.Name)
  Write-Host ('     esxcli system uuid = {0}' -f $su)
  Write-Host ('     hardware SMBIOS uuid = {0}' -f $hwuuid)
}
Write-Host ''
Write-Host '  --- VM placement ---'
Get-VM | Sort-Object Name | ForEach-Object {
  Write-Host ('     {0,-46} host={1} power={2}' -f $_.Name,$_.VMHost.Name,$_.PowerState)
}
Write-Host ''
Write-Host '  --- vSAN datastore ---'
Get-Datastore | Where-Object {$_.Type -eq 'vsan'} | ForEach-Object { Write-Host ('     {0} cap={1:N0}GB free={2:N0}GB' -f $_.Name,$_.CapacityGB,$_.FreeSpaceGB) }
Disconnect-VIServer 192.168.114.11 -Confirm:$false -Force | Out-Null

Write-Host ''
Write-Host '########## OUTER vCenter (nested VM bios uuid) ##########'
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null
foreach($n in 'vcf-m02-esx01-91','vcf-m02-esx02-91','vcf-m02-esx03-91','vcf-m02-esx04-91'){
  $vm=Get-VM -Name $n -ErrorAction SilentlyContinue
  if($vm){
    Write-Host ('  {0}  biosUuid={1}  instanceUuid={2}' -f $n,$vm.ExtensionData.Config.Uuid,$vm.ExtensionData.Config.InstanceUuid)
  }
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
