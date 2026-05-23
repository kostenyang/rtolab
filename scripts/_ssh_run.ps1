param([string]$Target,[string]$User='root',[string]$Pass='VMware1!VMware1!',[string]$Cmd)
$ErrorActionPreference='Stop'
Import-Module Posh-SSH
$sec=ConvertTo-SecureString $Pass -AsPlainText -Force
$cred=New-Object System.Management.Automation.PSCredential($User,$sec)
$s=New-SSHSession -ComputerName $Target -Credential $cred -AcceptKey -ConnectionTimeout 30 -Force
$r=Invoke-SSHCommand -SSHSession $s -Command $Cmd -TimeOut 120
Write-Output $r.Output
if($r.Error){ Write-Output "--STDERR--"; Write-Output $r.Error }
Remove-SSHSession -SSHSession $s | Out-Null
