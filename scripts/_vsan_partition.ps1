$ErrorActionPreference='Stop'
Import-Module VMware.VimAutomation.Core | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
Connect-VIServer 192.168.114.11 -User 'administrator@vsphere.local' -Password 'VMware1!VMware1!' | Out-Null
foreach($h in (Get-VMHost | Sort-Object Name)){
  Write-Host ('===== ' + $h.Name + ' =====')
  try{
    $e=Get-EsxCli -VMHost $h -V2
    $c=$e.vsan.cluster.get.Invoke()
    Write-Host ('  members={0}  state={1}  type={2}' -f $c.SubClusterMemberCount,$c.LocalNodeState,$c.LocalNodeType)
    Write-Host ('  memberHosts={0}' -f ($c.SubClusterMemberHostNames -join ','))
    $ua=$e.vsan.cluster.unicastagent.list.Invoke()
    Write-Host ('  unicastagents={0}' -f (($ua | ForEach-Object { $_.IPAddress }) -join ','))
    $vmk=$e.network.ip.interface.ipv4.address.list.Invoke() | Where-Object { $_.IPv4Address -like '192.168.116.*' }
    Write-Host ('  vsan vmk ip={0}' -f ($vmk.IPv4Address -join ','))
  }catch{ Write-Host ('  ERR ' + $_.Exception.Message) }
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
