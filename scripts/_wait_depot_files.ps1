<#  Watch depot 172.16.10.50 for the 2 missing files appearing.
    Polls every 60s. Exits when both present OR both download processes have died. #>
$ErrorActionPreference='Continue'
$start=Get-Date
$last=''
while($true){
  try{
    $r=Invoke-RestMethod -Uri 'http://172.16.10.50:8888/PROD/COMP/VCENTER/' -TimeoutSec 10
    $vlcm=$r -match 'VMware-vlcm-operator-9\.1\.0\.0\.25370922\.zip'
  }catch{ $vlcm=$false }
  try{
    $r=Invoke-RestMethod -Uri 'http://172.16.10.50:8888/PROD/COMP/NSX_T_MANAGER/' -TimeoutSec 10
    $nsxMub=$r -match 'VMware-NSX-upgrade-bundle-9\.1\.0\.0\.0?25318225\.mub'
  }catch{ $nsxMub=$false }
  $el=((Get-Date)-$start).ToString('hh\:mm\:ss')
  $line="vlcm-operator=$vlcm  nsx-upgrade-bundle.mub=$nsxMub"
  if($line -ne $last){ Write-Host ("[$el] $line"); $last=$line }
  if($vlcm -and $nsxMub){ Write-Host '=== BOTH MISSING FILES NOW PRESENT ==='; break }
  Start-Sleep 60
}
