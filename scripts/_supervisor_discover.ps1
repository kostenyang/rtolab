<#  Discovery for Supervisor enablement on vcf-m02-cl01.
    Dumps cluster id, VDS, NSX edge cluster, transport zones, storage policies,
    portgroup ids, datastore id, content library id — everything needed to
    build the PUT /api/vcenter/namespace-management/clusters/{id} spec. #>
$ErrorActionPreference='Stop'
$vc='192.168.114.11'
$vcUser='administrator@vsphere.local'
$vcPass='VMware1!VMware1!'
$nsxVip='192.168.114.13'
$nsxAdmin='admin'
$nsxPass='VMware1!VMware1!'

# vAPI session (new style)
$enc=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${vcUser}:${vcPass}"))
$sid=Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "https://$vc/api/session" -Headers @{Authorization="Basic $enc"} -TimeoutSec 30
$vh=@{'vmware-api-session-id'=$sid}

Write-Host '=== vCenter cluster ==='
$cl=Invoke-RestMethod -SkipCertificateCheck -Uri "https://$vc/api/vcenter/cluster?names=vcf-m02-cl01" -Headers $vh
$cl | Format-Table cluster,name -AutoSize | Out-String -Width 100 | Write-Host
$clId=$cl[0].cluster

Write-Host '=== Distributed Virtual Switches ==='
Import-Module VMware.VimAutomation.Core -ErrorAction SilentlyContinue
Import-Module VMware.VimAutomation.Storage -ErrorAction SilentlyContinue
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$pc=Connect-VIServer -Server $vc -User $vcUser -Password $vcPass -Force
$dvs=Get-VDSwitch
$dvs | Select Name,Id,Mtu,NumPorts,Version | Format-Table -AutoSize | Out-String -Width 130 | Write-Host

Write-Host '=== mgmt portgroup (where Supervisor VMs will live) ==='
$mgmtPg=Get-VDPortgroup | Where-Object { $_.VlanConfiguration.VlanId -eq 114 -or $_.Name -match 'mgmt|management|114' }
$mgmtPg | Select Name,VDSwitch,Id,@{n='Vlan';e={$_.VlanConfiguration.VlanId}} | Format-Table -AutoSize | Out-String -Width 130 | Write-Host

Write-Host '=== Storage policies (interested: FTT=0) ==='
$pol=Get-SpbmStoragePolicy -Name 'Management Storage Policy - Single Node'
Write-Host ('  policy: ' + $pol.Name + '   id: ' + $pol.Id)

Write-Host '=== Datastore ==='
$ds=Get-Datastore | Where-Object { $_.Name -match 'vsan' } | Select -First 1
Write-Host ('  datastore: ' + $ds.Name + '   id: ' + $ds.ExtensionData.MoRef.Value)

Write-Host '=== Content library ==='
$libs=Invoke-RestMethod -SkipCertificateCheck -Uri "https://$vc/api/content/library" -Headers $vh
foreach($l in $libs){ $d=Invoke-RestMethod -SkipCertificateCheck -Uri "https://$vc/api/content/library/$l" -Headers $vh; Write-Host ("  lib: $($d.name)  id=$l  type=$($d.type)") }

Write-Host '=== vCenter cluster compatibility for Supervisor (NSXT_CONTAINER_PLUGIN) ==='
try{
  $compat=Invoke-RestMethod -SkipCertificateCheck -Uri "https://$vc/api/vcenter/namespace-management/cluster-compatibility?network_provider=NSXT_CONTAINER_PLUGIN" -Headers $vh
  $compat | ConvertTo-Json -Depth 6 | Write-Host
}catch{ Write-Host ('  compat err: ' + $_.ErrorDetails.Message) }

Disconnect-VIServer * -Confirm:$false -Force | Out-Null

Write-Host ''
Write-Host '=== NSX Manager: edge clusters + transport zones ==='
$nsxAuth=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${nsxAdmin}:${nsxPass}"))
$nh=@{Authorization="Basic $nsxAuth"; 'Content-Type'='application/json'}
try{
  $ec=Invoke-RestMethod -SkipCertificateCheck -Uri "https://$nsxVip/api/v1/edge-clusters" -Headers $nh -TimeoutSec 30
  Write-Host '--- edge clusters ---'
  $ec.results | Select display_name,id,@{n='members';e={$_.members.Count}} | Format-Table -AutoSize | Out-String -Width 120 | Write-Host

  $tz=Invoke-RestMethod -SkipCertificateCheck -Uri "https://$nsxVip/api/v1/transport-zones" -Headers $nh -TimeoutSec 30
  Write-Host '--- transport zones ---'
  $tz.results | Select display_name,id,transport_type,host_switch_name | Format-Table -AutoSize | Out-String -Width 130 | Write-Host

  $tnp=Invoke-RestMethod -SkipCertificateCheck -Uri "https://$nsxVip/api/v1/transport-node-profiles" -Headers $nh -TimeoutSec 30
  Write-Host '--- transport node profiles ---'
  $tnp.results | Select display_name,id | Format-Table -AutoSize | Out-String -Width 100 | Write-Host
}catch{ Write-Host ('NSX api err: ' + $_.Exception.Message.Substring(0,[Math]::Min(160,$_.Exception.Message.Length))) }
