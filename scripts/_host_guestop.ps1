<#  Run a /bin/sh command on the 4 nested ESXi 9.1 VMs via GuestOps. #>
param(
  [string]$Command,
  [string[]]$Vms = @('vcf-m02-esx01-91','vcf-m02-esx02-91','vcf-m02-esx03-91','vcf-m02-esx04-91')
)
$ErrorActionPreference='Stop'
$repoRoot='c:\Users\Administrator\rtolab'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$inv=Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets=Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null
$si=Get-View ServiceInstance
$gom=Get-View $si.Content.GuestOperationsManager
$pm=Get-View $gom.ProcessManager
$fm=Get-View $gom.FileManager
$auth=New-Object VMware.Vim.NamePasswordAuthentication -Property @{Username='root';Password=$secrets.esxi.root_pw;InteractiveSession=$false}
foreach($vmName in $Vms){
  try{
    $vm=Get-VM -Name $vmName -ErrorAction Stop
    $mo=$vm.ExtensionData.MoRef
    $wrapper="#!/bin/sh`n$Command`n"
    $tmp=New-TemporaryFile
    Set-Content -Path $tmp -Value $wrapper -Encoding UTF8 -NoNewline
    $bytes=[IO.File]::ReadAllBytes($tmp)
    $attr=New-Object VMware.Vim.GuestFileAttributes
    $urlUp=$fm.InitiateFileTransferToGuest($mo,$auth,'/tmp/runcmd.sh',$attr,$bytes.Length,$true)
    Invoke-WebRequest -Uri $urlUp -Method Put -Body $bytes -ContentType 'application/octet-stream' -SkipCertificateCheck -UseBasicParsing | Out-Null
    Remove-Item $tmp -Force
    $spec=New-Object VMware.Vim.GuestProgramSpec -Property @{ProgramPath='/bin/sh';Arguments='-c "chmod +x /tmp/runcmd.sh && /bin/sh /tmp/runcmd.sh > /tmp/runcmd.out 2>&1"';WorkingDirectory='/tmp'}
    $gpid=$pm.StartProgramInGuest($mo,$auth,$spec)
    for($i=0;$i -lt 120;$i++){ $p=$pm.ListProcessesInGuest($mo,$auth,@($gpid)); if($p[0].EndTime){break}; Start-Sleep 1 }
    $info=$fm.InitiateFileTransferFromGuest($mo,$auth,'/tmp/runcmd.out')
    $r=Invoke-WebRequest -Uri $info.Url -SkipCertificateCheck -UseBasicParsing
    $text=[System.Text.Encoding]::UTF8.GetString($r.Content)
    Write-Host "===== $vmName ====="
    Write-Host $text
  }catch{
    Write-Host "===== $vmName ERROR ====="
    Write-Host $_.Exception.Message
  }
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
