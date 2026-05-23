<#  Run a /bin/bash command inside the VCF Installer 9.1 VM via GuestOps. #>
param([string]$Command,[string]$VmName='')
$ErrorActionPreference='Stop'
$repoRoot='c:\Users\Administrator\rtolab'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$inv=Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets=Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null
if(-not $VmName){
  $cand=Get-VM | Where-Object { $_.Name -match 'inst' -and $_.Name -match '91' }
  if(-not $cand){ $cand=Get-VM | Where-Object { $_.Guest.HostName -match 'inst' } }
  if($cand.Count -gt 1){ Write-Host ("multiple: " + ($cand.Name -join ', ')) }
  $vm=$cand | Select-Object -First 1
}else{ $vm=Get-VM -Name $VmName }
if(-not $vm){ throw "Installer VM not found" }
Write-Host "VM: $($vm.Name)  power=$($vm.PowerState)"
$mo=$vm.ExtensionData.MoRef
$si=Get-View ServiceInstance
$gom=Get-View $si.Content.GuestOperationsManager
$pm=Get-View $gom.ProcessManager
$fm=Get-View $gom.FileManager
$auth=New-Object VMware.Vim.NamePasswordAuthentication -Property @{Username='root';Password=$secrets.vcf_installer.root_pw;InteractiveSession=$false}
$wrapper="#!/bin/bash`n$Command`n"
$tmp=New-TemporaryFile
Set-Content -Path $tmp -Value $wrapper -Encoding UTF8 -NoNewline
$bytes=[IO.File]::ReadAllBytes($tmp)
$attr=New-Object VMware.Vim.GuestFileAttributes
$urlUp=$fm.InitiateFileTransferToGuest($mo,$auth,'/tmp/igc.sh',$attr,$bytes.Length,$true)
Invoke-WebRequest -Uri $urlUp -Method Put -Body $bytes -ContentType 'application/octet-stream' -SkipCertificateCheck -UseBasicParsing | Out-Null
Remove-Item $tmp -Force
$spec=New-Object VMware.Vim.GuestProgramSpec -Property @{ProgramPath='/bin/bash';Arguments='-c "chmod +x /tmp/igc.sh && /bin/bash /tmp/igc.sh > /tmp/igc.out 2>&1"';WorkingDirectory='/tmp'}
$gpid=$pm.StartProgramInGuest($mo,$auth,$spec)
for($i=0;$i -lt 180;$i++){ $p=$pm.ListProcessesInGuest($mo,$auth,@($gpid)); if($p[0].EndTime){break}; Start-Sleep 1 }
$info=$fm.InitiateFileTransferFromGuest($mo,$auth,'/tmp/igc.out')
$r=Invoke-WebRequest -Uri $info.Url -SkipCertificateCheck -UseBasicParsing
Write-Host ([System.Text.Encoding]::UTF8.GetString($r.Content))
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
