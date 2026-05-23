<#  Configure NTP on the 4 nested ESXi via PowerCLI (port 443; SSH is off).
    Points ntpd at 192.168.114.200, sets policy On, starts the service. #>
$ErrorActionPreference='Stop'
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$ntp='192.168.114.200'
$pw='VMware1!VMware1!'
foreach($ip in '192.168.114.14','192.168.114.15','192.168.114.16','192.168.114.17'){
  try{
    $vi=Connect-VIServer -Server $ip -User root -Password $pw -Force -ErrorAction Stop
    $h=Get-VMHost -Server $vi
    Get-VMHostNtpServer -VMHost $h | ForEach-Object { Remove-VMHostNtpServer -VMHost $h -NtpServer $_ -Confirm:$false }
    Add-VMHostNtpServer -VMHost $h -NtpServer $ntp -Confirm:$false | Out-Null
    $svc=Get-VMHostService -VMHost $h | Where-Object { $_.Key -eq 'ntpd' }
    Set-VMHostService -HostService $svc -Policy On -Confirm:$false | Out-Null
    if($svc.Running){ Restart-VMHostService -HostService $svc -Confirm:$false | Out-Null }
    else { Start-VMHostService -HostService $svc -Confirm:$false | Out-Null }
    $svc2=Get-VMHostService -VMHost $h | Where-Object { $_.Key -eq 'ntpd' }
    $cfg=(Get-VMHostNtpServer -VMHost $h) -join ','
    Write-Host ("{0}  ntp={1}  policy={2}  running={3}" -f $ip,$cfg,$svc2.Policy,$svc2.Running)
    Disconnect-VIServer -Server $vi -Confirm:$false -Force | Out-Null
  }catch{
    Write-Host ("{0}  FAILED: {1}" -f $ip,$_.Exception.Message)
  }
}
