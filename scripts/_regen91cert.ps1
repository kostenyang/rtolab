$ProgressPreference='SilentlyContinue'
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$repoRoot = 'c:\Users\Administrator\rtolab'
$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null

$si  = Get-View ServiceInstance
$gom = Get-View $si.Content.GuestOperationsManager
$pm  = Get-View $gom.ProcessManager
$fm  = Get-View $gom.FileManager
$auth = New-Object VMware.Vim.NamePasswordAuthentication -Property @{ Username='root'; Password=$secrets.esxi.root_pw; InteractiveSession=$false }

$hosts = @(
  @{ VM='vcf-m02-esx01-91'; FQDN='kosten-vcf91-esx01.rtolab.local' },
  @{ VM='vcf-m02-esx02-91'; FQDN='kosten-vcf91-esx02.rtolab.local' },
  @{ VM='vcf-m02-esx03-91'; FQDN='kosten-vcf91-esx03.rtolab.local' },
  @{ VM='vcf-m02-esx04-91'; FQDN='kosten-vcf91-esx04.rtolab.local' }
)

foreach ($h in $hosts) {
  $vm = Get-VM -Name $h.VM
  Write-Host "=== $($h.VM) regen cert ===" -ForegroundColor Cyan
  $sh = @"
#!/bin/sh
set -x
esxcli system hostname set --fqdn='$($h.FQDN)'
SHORT=`$(echo '$($h.FQDN)' | cut -d. -f1)
esxcli system hostname set --host="`$SHORT"
esxcli system hostname set --domain='rtolab.local'
/sbin/generate-certificates
/etc/init.d/hostd restart
/etc/init.d/rhttpproxy restart
sleep 5
openssl x509 -in /etc/vmware/ssl/rui.crt -noout -subject
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
vim-cmd hostsvc/net/info > /dev/null 2>&1
/sbin/auto-backup.sh
echo REGEN_DONE
"@
  $tmp = New-TemporaryFile
  Set-Content -Path $tmp -Value $sh -Encoding ASCII -NoNewline
  $bytes = [IO.File]::ReadAllBytes($tmp)
  $attr = New-Object VMware.Vim.GuestFileAttributes
  $url = $fm.InitiateFileTransferToGuest($vm.ExtensionData.MoRef, $auth, '/tmp/regen.sh', $attr, $bytes.Length, $true)
  Invoke-WebRequest -Uri $url -Method Put -Body $bytes -ContentType 'application/octet-stream' -SkipCertificateCheck -UseBasicParsing | Out-Null
  Remove-Item $tmp -Force

  $spec = New-Object VMware.Vim.GuestProgramSpec -Property @{
    ProgramPath='/bin/sh'; Arguments='-c "/bin/sh /tmp/regen.sh > /tmp/regen.out 2>&1"'; WorkingDirectory='/tmp'
  }
  $gpid = $pm.StartProgramInGuest($vm.ExtensionData.MoRef, $auth, $spec)
  for ($i=0; $i -lt 120; $i++) {
    $p = $pm.ListProcessesInGuest($vm.ExtensionData.MoRef, $auth, @($gpid))
    if ($p[0].EndTime) { break }
    Start-Sleep 1
  }
  $info = $fm.InitiateFileTransferFromGuest($vm.ExtensionData.MoRef, $auth, '/tmp/regen.out')
  $out = (Invoke-WebRequest -Uri $info.Url -SkipCertificateCheck -UseBasicParsing).Content
  $txt = [System.Text.Encoding]::UTF8.GetString($out)
  ($txt -split "`n") | Where-Object { $_ -match 'subject|REGEN_DONE|Running|error|Error' } | Select-Object -Last 6 | ForEach-Object { Write-Host "  $_" }
}
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Write-Host "REGEN ALL DONE"
