$ErrorActionPreference='Stop'
$repoRoot='c:\Users\Administrator\rtolab'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$inv=Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets=Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null
foreach($pgName in 'trunk','selab-dswitch-pg114','selab-dswitch-pg115','selab-dswitch-pg116','selab-dswitch-pg117'){
  $pg=Get-VDPortgroup -Name $pgName -ErrorAction SilentlyContinue
  if(-not $pg){ Write-Host "$pgName : NOT FOUND"; continue }
  $v=$pg.ExtensionData.Config.DefaultPortConfig
  $sec=$v.SecurityPolicy
  $vlan=$v.Vlan
  $vlanTxt=if($vlan -is [VMware.Vim.VmwareDistributedVirtualSwitchTrunkVlanSpec]){ 'TRUNK ' + (($vlan.VlanId | ForEach-Object { "$($_.Start)-$($_.End)" }) -join ',') } elseif($vlan){ "VLAN $($vlan.VlanId)" } else { '?' }
  Write-Host ("=== {0} ===" -f $pgName)
  Write-Host ("  vlan         : {0}" -f $vlanTxt)
  Write-Host ("  promiscuous  : {0}" -f $sec.AllowPromiscuous.Value)
  Write-Host ("  forgedXmit   : {0}" -f $sec.ForgedTransmits.Value)
  Write-Host ("  macChanges   : {0}" -f $sec.MacChanges.Value)
  $ml=$v.MacManagementPolicy
  if($ml){
    Write-Host ("  macMgmt.macLearning.enabled       : {0}" -f $ml.MacLearningPolicy.Enabled)
    Write-Host ("  macMgmt.macLearning.allowUnicastFlooding: {0}" -f $ml.MacLearningPolicy.AllowUnicastFlooding)
    Write-Host ("  macMgmt.macLearning.limit         : {0}" -f $ml.MacLearningPolicy.Limit)
    Write-Host ("  macMgmt.forgedTransmits           : {0}" -f $ml.ForgedTransmits)
    Write-Host ("  macMgmt.macChanges                : {0}" -f $ml.MacChanges)
  } else { Write-Host "  macMgmt      : (none)" }
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
