$ErrorActionPreference='Stop'
Import-Module VMware.VimAutomation.Core | Out-Null
Import-Module VMware.VimAutomation.Storage -ErrorAction SilentlyContinue | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
Connect-VIServer 192.168.114.11 -User 'administrator@vsphere.local' -Password 'VMware1!VMware1!' | Out-Null

Write-Host '=== vSAN datastore ==='
Get-Datastore | Where-Object { $_.Type -eq 'vsan' } | ForEach-Object {
  Write-Host ('  {0}  capacityGB={1:N0}  freeGB={2:N0}' -f $_.Name,$_.CapacityGB,$_.FreeSpaceGB)
}
Write-Host ''
Write-Host '=== SPBM storage policies (vSAN) ==='
Get-SpbmStoragePolicy -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'vSAN|VCF|Management' } | ForEach-Object {
  Write-Host ('  POLICY: {0}' -f $_.Name)
  foreach($rs in $_.AnyOfRuleSets){
    foreach($r in $rs.AllOfRules){ Write-Host ('     {0} = {1}' -f $r.Capability.Name,$r.Value) }
  }
}
Write-Host ''
Write-Host '=== VM storage policy assignment ==='
Get-VM -ErrorAction SilentlyContinue | ForEach-Object {
  $pol=(Get-SpbmEntityConfiguration -VM $_ -ErrorAction SilentlyContinue).StoragePolicy.Name
  Write-Host ('  {0,-32} policy={1}' -f $_.Name,$pol)
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
