$ErrorActionPreference='Stop'
Import-Module VMware.VimAutomation.Core | Out-Null
Import-Module VMware.VimAutomation.Storage -ErrorAction SilentlyContinue | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
Connect-VIServer 192.168.114.11 -User 'administrator@vsphere.local' -Password 'VMware1!VMware1!' | Out-Null

$cl = Get-Cluster | Select-Object -First 1
Write-Host ('cluster: {0}  vSAN={1}' -f $cl.Name,$cl.VsanEnabled)
Write-Host '=== hosts ==='
Get-VMHost | Sort-Object Name | ForEach-Object { Write-Host ('  {0}  state={1}' -f $_.Name,$_.ConnectionState) }

Write-Host ''
Write-Host '=== vSAN disks per host (esxcli) ==='
foreach($h in (Get-VMHost | Sort-Object Name)){
  try{
    $esxcli = Get-EsxCli -VMHost $h -V2
    $pool = $esxcli.vsan.storagepool.list.Invoke()
    $cnt = ($pool | Measure-Object).Count
    Write-Host ('  {0}: storagepool disks={1}' -f $h.Name,$cnt)
    foreach($d in $pool){ Write-Host ('      {0}  {1}' -f $d.Device,$d.IsMounted) }
  }catch{ Write-Host ('  {0}: storagepool query failed: {1}' -f $h.Name,$_.Exception.Message) }
}

Write-Host ''
Write-Host '=== all storage policies ==='
Get-SpbmStoragePolicy -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ('  ' + $_.Name) }
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
