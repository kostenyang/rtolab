param([string]$Target,[string]$User='root',[string]$Pass='VMware1!VMware1!',[string]$Local,[string]$RemoteDir='/root')
$ErrorActionPreference='Stop'
Import-Module Posh-SSH
$sec=ConvertTo-SecureString $Pass -AsPlainText -Force
$cred=New-Object System.Management.Automation.PSCredential($User,$sec)
$sf=New-SFTPSession -ComputerName $Target -Credential $cred -AcceptKey -ConnectionTimeout 30 -Force
Set-SFTPItem -SFTPSession $sf -Path $Local -Destination $RemoteDir -Force
Write-Host ("uploaded {0} -> {1}/{2}" -f $Local,$RemoteDir,(Split-Path $Local -Leaf))
Remove-SFTPSession -SFTPSession $sf | Out-Null
